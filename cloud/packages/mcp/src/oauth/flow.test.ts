import { createHash } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate } from "../../../db/src/client.js";
import { mcpOauthFlows, mcpOauthTokens, mcpServers } from "../../../db/src/repos.js";
import { users } from "../../../db/src/schema.js";
import { createEnvelopeCrypto } from "../crypto.js";
import { createGuardedFetch } from "../ssrf.js";
import {
  DEFAULT_MCP_REDIRECT_URI,
  OAUTH_FLOW_TTL_MS,
  buildAuthorizeUrl,
  createOAuthFlow,
  pkcePair,
} from "./flow.js";

// Flow tests run against a LIVE fixture authorization server on 127.0.0.1
// (http loopback — the Task-3 guard's literal-loopback test-mode exemption)
// reached through the REAL guarded egress, plus real Postgres tables from
// @ovid/db (Task 8). Gated on TEST_DATABASE_URL like mcpRepos.test.ts.

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const FIXTURE_ACCESS_TOKEN = "fixture-access-token-4f7c29d1";
const FIXTURE_REFRESH_TOKEN = "fixture-refresh-token-8e1d33b7";

interface AsRequest {
  method: string;
  url: string;
  body?: string;
  contentType?: string;
}

/** A minimal RFC 9728/8414/7591 authorization server on 127.0.0.1. */
class FixtureAS {
  readonly requests: AsRequest[] = [];
  tokenResponse: { status: number; body?: unknown; location?: string } = {
    status: 200,
    body: {
      access_token: FIXTURE_ACCESS_TOKEN,
      token_type: "Bearer",
      refresh_token: FIXTURE_REFRESH_TOKEN,
      expires_in: 3600,
    },
  };
  #server: Server | undefined;
  port = 0;

  get origin(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  async start(): Promise<void> {
    this.#server = createServer((req, res) => {
      void this.#handle(req, res);
    });
    await new Promise<void>((resolve) => this.#server!.listen(0, "127.0.0.1", resolve));
    this.port = (this.#server!.address() as { port: number }).port;
  }

  async stop(): Promise<void> {
    const server = this.#server;
    if (!server) return;
    this.#server = undefined;
    server.closeAllConnections?.();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  async #handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const body = Buffer.concat(chunks).toString("utf8");
    const url = req.url ?? "/";
    this.requests.push({
      method: req.method ?? "GET",
      url,
      body: body === "" ? undefined : body,
      contentType: req.headers["content-type"],
    });
    const json = (obj: unknown, status = 200): void => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    // RFC 9728 PRM: path-aware candidate 404s, root answers.
    if (req.method === "GET" && url === "/.well-known/oauth-protected-resource/mcp") {
      res.writeHead(404);
      res.end();
      return;
    }
    if (req.method === "GET" && url === "/.well-known/oauth-protected-resource") {
      json({ resource: `${this.origin}/mcp`, authorization_servers: [this.origin] });
      return;
    }
    // RFC 8414 AS metadata on the issuer (= server origin; PRM lists it).
    if (req.method === "GET" && url === "/.well-known/oauth-authorization-server") {
      json({
        issuer: this.origin,
        authorization_endpoint: `${this.origin}/as/authorize`,
        token_endpoint: `${this.origin}/as/token`,
        registration_endpoint: `${this.origin}/as/register`,
        code_challenge_methods_supported: ["S256"],
      });
      return;
    }
    if (req.method === "GET" && url === "/.well-known/openid-configuration") {
      res.writeHead(404);
      res.end();
      return;
    }
    // RFC 7591 dynamic client registration.
    if (req.method === "POST" && url === "/as/register") {
      json({ client_id: "dcr-client-1", client_secret: "dcr-secret-1" });
      return;
    }
    if (req.method === "POST" && url === "/as/token") {
      const t = this.tokenResponse;
      if (t.location !== undefined) {
        res.writeHead(t.status, { location: t.location });
        res.end();
        return;
      }
      json(t.body ?? {}, t.status);
      return;
    }
    res.writeHead(404);
    res.end();
  }
}

function sha256base64url(value: string): string {
  return createHash("sha256").update(value, "ascii").digest("base64url");
}

// ---------------------------------------------------------------------------
// Pure units: pkcePair + buildAuthorizeUrl (no DB, no fixture server)
// ---------------------------------------------------------------------------

describe("pkcePair", () => {
  it("S256: challenge = base64url(sha256(verifier)), no padding, injectable randomness", () => {
    const fixed = (n: number): Buffer => Buffer.alloc(n, 0x41);
    const { verifier, challenge } = pkcePair(fixed);
    expect(verifier).toBe(Buffer.alloc(32, 0x41).toString("base64url"));
    expect(challenge).toBe(sha256base64url(verifier));
    expect(verifier).not.toContain("=");
    expect(challenge).not.toContain("=");
  });

  it("default randomness: 43-char base64url, unguessable per call", () => {
    const a = pkcePair();
    const b = pkcePair();
    expect(a.verifier).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(a.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(a.challenge).toBe(sha256base64url(a.verifier));
    expect(a.verifier).not.toBe(b.verifier);
    expect(a.challenge).not.toBe(b.challenge);
  });
});

describe("buildAuthorizeUrl", () => {
  const cfg = {
    authorizationUrl: "https://as.example/authorize?prompt=consent",
    tokenUrl: "https://as.example/token",
    clientId: "client-1",
    scopes: ["read", "write"],
    resource: "https://mcp.example/mcp",
    issuer: "https://as.example",
    discovered: true,
  };

  it("builds the authorization URL with state, S256 challenge, resource and preserved query", () => {
    const url = new URL(
      buildAuthorizeUrl(cfg, {
        state: "state-xyz",
        codeChallenge: "challenge-abc",
        redirectUri: "https://ovidsi.com/oauth/callback",
      }),
    );
    expect(url.origin + url.pathname).toBe("https://as.example/authorize");
    const q = url.searchParams;
    expect(q.get("prompt")).toBe("consent"); // pre-existing param preserved
    expect(q.get("response_type")).toBe("code");
    expect(q.get("client_id")).toBe("client-1");
    expect(q.get("redirect_uri")).toBe("https://ovidsi.com/oauth/callback");
    expect(q.get("scope")).toBe("read write");
    expect(q.get("resource")).toBe("https://mcp.example/mcp"); // RFC 8707
    expect(q.get("state")).toBe("state-xyz");
    expect(q.get("code_challenge")).toBe("challenge-abc");
    expect(q.get("code_challenge_method")).toBe("S256");
    // spaces are percent-encoded (Dart parity), never "+"
    expect(url.search).toContain("scope=read%20write");
  });

  it("omits scope/resource when unset; throws without clientId or authorizationUrl", () => {
    const url = new URL(
      buildAuthorizeUrl(
        { authorizationUrl: "https://as.example/authorize", tokenUrl: "https://as.example/token", clientId: "client-1", scopes: [], discovered: false },
        { state: "s", codeChallenge: "c", redirectUri: "https://cb.example/cb" },
      ),
    );
    expect(url.searchParams.has("scope")).toBe(false);
    expect(url.searchParams.has("resource")).toBe(false);

    expect(() =>
      buildAuthorizeUrl(
        { authorizationUrl: "https://as.example/authorize", tokenUrl: "t", scopes: [], discovered: false },
        { state: "s", codeChallenge: "c", redirectUri: "https://cb.example/cb" },
      ),
    ).toThrow(/no client_id/);
    expect(() =>
      buildAuthorizeUrl(
        { authorizationUrl: "", tokenUrl: "t", clientId: "c", scopes: [], discovered: false },
        { state: "s", codeChallenge: "c", redirectUri: "https://cb.example/cb" },
      ),
    ).toThrow(/no authorization_url/);
  });
});

// ---------------------------------------------------------------------------
// The flow: real Postgres (Task 8 tables) + live fixture AS through the
// guarded egress. Gated on TEST_DATABASE_URL.
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL)("MCP OAuth flow (discovery → PKCE → sealed token store)", () => {
  let db: ReturnType<typeof createDb>;
  const as = new FixtureAS();

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    // Idempotent migrate only — NO schema drop: other parallel-wave lanes run
    // their own suites against this same dev Postgres, and this file never
    // needs a from-scratch journal re-run (mcpRepos.test.ts owns that).
    await migrate(url);
    db = createDb(url);
    await as.start();
  }, 60_000);

  afterAll(async () => {
    await as.stop();
    await db?.$client.end({ timeout: 5 });
  });

  function testUid(): string {
    return `oau-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  }

  async function seedUser(): Promise<string> {
    const uid = testUid();
    await db.insert(users).values({ uid, email: `u-${uid.slice(0, 12)}@test.local` });
    return uid;
  }

  async function seedServer(uid: string, url = `${as.origin}/mcp`): Promise<{ id: string }> {
    return mcpServers.create(db, {
      userId: uid,
      name: `as-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`,
      transport: "http",
      config: { url, type: "http" },
    });
  }

  interface Published {
    uid: string;
    event: { kind: string; requiresResponse?: boolean; payload: Record<string, unknown> };
  }

  const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);

  function makeFlow(events: Published[], redirectUri = DEFAULT_MCP_REDIRECT_URI) {
    return createOAuthFlow({
      db,
      crypto,
      systemBus: {
        publish: async (uid: string, event: Published["event"]) => {
          events.push({ uid, event: JSON.parse(JSON.stringify(event)) });
        },
      },
      fetchImpl: createGuardedFetch({ allowedPorts: [as.port] }),
      redirectUri,
    });
  }

  async function flowRow(state: string): Promise<Record<string, unknown> | null> {
    const rows = await db.$client.unsafe(`SELECT * FROM mcp_oauth_flows WHERE state = $1`, [state]);
    return (rows as Record<string, unknown>[])[0] ?? null;
  }

  function stateOf(authorizeUrl: string): string {
    return new URL(authorizeUrl).searchParams.get("state")!;
  }

  it("start persists a one-use flow row (sealed verifier) and returns authorizeUrl with state+challenge+resource", async () => {
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await makeFlow([]).start(uid, server.id);

    const u = new URL(authorizeUrl);
    expect(u.origin + u.pathname).toBe(`${as.origin}/as/authorize`);
    const q = u.searchParams;
    expect(q.get("response_type")).toBe("code");
    expect(q.get("client_id")).toBe("dcr-client-1"); // DCR registered a public client
    expect(q.get("redirect_uri")).toBe(DEFAULT_MCP_REDIRECT_URI);
    expect(q.get("scope")).toBe(null); // no scopes declared anywhere
    expect(q.get("resource")).toBe(`${as.origin}/mcp`); // RFC 8707
    expect(q.get("state")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(q.get("code_challenge")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(q.get("code_challenge_method")).toBe("S256");

    const state = q.get("state")!;
    const row = await flowRow(state);
    expect(row).not.toBeNull();
    expect(row!.user_id).toBe(uid);
    expect(row!.server_id).toBe(server.id);
    expect(row!.used).toBe(false);
    const expiresAt = new Date(row!.expires_at as string | Date);
    expect(expiresAt.valueOf()).toBeGreaterThan(Date.now() + OAUTH_FLOW_TTL_MS - 30_000);
    expect(expiresAt.valueOf()).toBeLessThan(Date.now() + OAUTH_FLOW_TTL_MS + 30_000);

    // The PKCE verifier is SEALED (recordId mcp_oauth_flows:{state}) and the
    // S256 challenge in the authorize URL is derived from exactly that value.
    const sealed = row!.verifier_sealed as { wrappedDek: string; iv: string; ciphertext: string; tag: string };
    expect(typeof sealed.wrappedDek).toBe("string");
    const secrets = JSON.parse(crypto.decrypt(sealed, `mcp_oauth_flows:${state}`)) as {
      verifier: string;
      clientSecret: string | null;
    };
    expect(secrets.verifier).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(sha256base64url(secrets.verifier)).toBe(q.get("code_challenge"));
    expect(secrets.clientSecret).toBe("dcr-secret-1"); // sealed, never a plain column

    // The plain config column carries the non-secret discovery result only.
    const config = row!.config as Record<string, unknown>;
    expect(config.tokenUrl).toBe(`${as.origin}/as/token`);
    expect(config.clientId).toBe("dcr-client-1");
    expect(JSON.stringify(config)).not.toContain("dcr-secret-1");
  });

  it("handleCallback with valid state+code exchanges at the token endpoint (code_verifier matches the sealed value), seals tokens, publishes mcp_oauth_completed", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await flow.start(uid, server.id);
    const state = stateOf(authorizeUrl);

    // Capture the sealed verifier before the callback consumes the row.
    const before = await flowRow(state);
    const sealedBefore = before!.verifier_sealed as Parameters<typeof crypto.decrypt>[0];
    const verifier = (
      JSON.parse(crypto.decrypt(sealedBefore, `mcp_oauth_flows:${state}`)) as { verifier: string }
    ).verifier;

    const result = await flow.handleCallback({ state, code: "auth-code-1", iss: as.origin });
    expect(result).toEqual({ uid, serverId: server.id, ok: true });

    // The exchange POST at the token endpoint used the SEALED verifier.
    const tokenReq = as.requests.find(
      (r) => r.method === "POST" && r.url === "/as/token" && (r.body ?? "").includes("code=auth-code-1"),
    )!;
    expect(tokenReq.contentType).toBe("application/x-www-form-urlencoded");
    const body = new URLSearchParams(tokenReq.body!);
    expect(body.get("grant_type")).toBe("authorization_code");
    expect(body.get("code")).toBe("auth-code-1");
    expect(body.get("redirect_uri")).toBe(DEFAULT_MCP_REDIRECT_URI);
    expect(body.get("client_id")).toBe("dcr-client-1");
    expect(body.get("client_secret")).toBe("dcr-secret-1"); // DCR secret travels from the seal
    expect(body.get("resource")).toBe(`${as.origin}/mcp`);
    expect(body.get("code_verifier")).toBe(verifier);

    // Tokens are sealed under mcp_oauth_tokens:{serverId} — with their own
    // refresh coordinates so a later refresh needs nothing else.
    const tokRow = await mcpOauthTokens.get(db, server.id, uid);
    expect(tokRow).not.toBeNull();
    const tokens = JSON.parse(
      crypto.decrypt(tokRow!.tokensSealed, `mcp_oauth_tokens:${server.id}`),
    ) as Record<string, unknown>;
    expect(tokens.accessToken).toBe(FIXTURE_ACCESS_TOKEN);
    expect(tokens.refreshToken).toBe(FIXTURE_REFRESH_TOKEN);
    expect(tokens.expiresAt as number).toBeGreaterThan(Date.now() + 3_500_000);
    expect(tokens.tokenUrl).toBe(`${as.origin}/as/token`);
    expect(tokens.clientId).toBe("dcr-client-1");

    // The flow row is consumed (one-use) — atomically, not by this code.
    expect((await flowRow(state))!.used).toBe(true);

    // mcp_oauth_completed {serverId, ok:true} went to the system bus.
    expect(events).toHaveLength(1);
    expect(events[0].uid).toBe(uid);
    expect(events[0].event.kind).toBe("mcp_oauth_completed");
    expect(events[0].event.requiresResponse).toBeFalsy();
    expect(events[0].event.payload).toEqual({ serverId: server.id, ok: true });

    // SECRET-HYGIENE PIN: no publish payload and no non-sealed DB column ever
    // contains the fixture access token (sealed columns may hold only
    // ciphertext — they are checked too, must not contain it either).
    expect(JSON.stringify(events)).not.toContain(FIXTURE_ACCESS_TOKEN);
    const flowRowStripped = { ...(await flowRow(state))! } as Record<string, unknown>;
    delete flowRowStripped.verifier_sealed;
    const tokenRowStripped = { ...tokRow! } as Record<string, unknown>;
    delete tokenRowStripped.tokensSealed;
    expect(JSON.stringify(flowRowStripped)).not.toContain(FIXTURE_ACCESS_TOKEN);
    expect(JSON.stringify(tokenRowStripped)).not.toContain(FIXTURE_ACCESS_TOKEN);
    expect(JSON.stringify(tokRow!.tokensSealed)).not.toContain(FIXTURE_ACCESS_TOKEN);
  });

  it("replayed state → {ok:false, reason:'oauth_failed'}; no second event", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await flow.start(uid, server.id);
    const state = stateOf(authorizeUrl);
    const first = await flow.handleCallback({ state, code: "auth-code-2" });
    expect(first.ok).toBe(true);
    const eventsAfterFirst = events.length;

    const replay = await flow.handleCallback({ state, code: "auth-code-2" });
    expect(replay).toEqual({ uid: "", serverId: "", ok: false, reason: "oauth_failed" });
    expect(events).toHaveLength(eventsAfterFirst); // unknown state → nothing published
  });

  it("unknown state → {ok:false}; no events", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const res = await flow.handleCallback({ state: "never-started-state", code: "c" });
    expect(res).toEqual({ uid: "", serverId: "", ok: false, reason: "oauth_failed" });
    expect(events).toHaveLength(0);
  });

  it("expired flow → ok:false", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    // A flow row whose expires_at is already past (created directly — the
    // flow's consume predicate is the DB's, Task 8). Unique per run: the
    // state is the PK and this suite never drops schema.
    const expiredState = `expired-flow-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await mcpOauthFlows.create(db, {
      state: expiredState,
      userId: uid,
      serverId: server.id,
      verifierSealed: null,
      config: null,
      expiresAt: new Date(Date.now() - 1_000),
    });
    const res = await flow.handleCallback({ state: expiredState, code: "late" });
    expect(res).toEqual({ uid: "", serverId: "", ok: false, reason: "oauth_failed" });
    expect(events).toHaveLength(0);
    expect(as.requests.some((r) => (r.body ?? "").includes("code=late"))).toBe(false);
  });

  it("iss param mismatch vs cfg.issuer → ok:false, mcp_oauth_failed published, no exchange", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await flow.start(uid, server.id);
    const state = stateOf(authorizeUrl);
    const postsBefore = as.requests.length;

    const res = await flow.handleCallback({ state, code: "auth-code-3", iss: "http://evil.example/as" });
    expect(res).toEqual({ uid, serverId: server.id, ok: false, reason: "oauth_failed" });
    expect(events).toHaveLength(1);
    expect(events[0].event.kind).toBe("mcp_oauth_failed");
    expect(events[0].event.payload).toEqual({ serverId: server.id, ok: false });
    expect(as.requests.length).toBe(postsBefore); // RFC 9207 mix-up defence: no exchange
  });

  it("error param → publishes mcp_oauth_failed with the sanitized error code", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await flow.start(uid, server.id);
    const state = stateOf(authorizeUrl);

    const res = await flow.handleCallback({ state, error: "access_denied" });
    expect(res).toEqual({ uid, serverId: server.id, ok: false, reason: "oauth_failed" });
    expect(events).toHaveLength(1);
    expect(events[0].event.kind).toBe("mcp_oauth_failed");
    expect(events[0].event.payload).toEqual({ serverId: server.id, ok: false, error: "access_denied" });

    // Unsanitizable error codes collapse to "error" — never echoed raw.
    const events2: Published[] = [];
    const flow2 = makeFlow(events2);
    const uid2 = await seedUser();
    const server2 = await seedServer(uid2);
    const { authorizeUrl: url2 } = await flow2.start(uid2, server2.id);
    const res2 = await flow2.handleCallback({
      state: stateOf(url2),
      error: "bad <script> injection",
    });
    expect(res2.ok).toBe(false);
    expect(events2[0].event.payload).toEqual({ serverId: server2.id, ok: false, error: "error" });
  });

  it("missing code and exchange failures (HTTP error / redirect / malformed body) → ok:false + mcp_oauth_failed, tokens never stored", async () => {
    const uid = await seedUser();
    const server = await seedServer(uid);

    const missingCode: Published[] = [];
    const flowA = makeFlow(missingCode);
    const { authorizeUrl: urlA } = await flowA.start(uid, server.id);
    const resA = await flowA.handleCallback({ state: stateOf(urlA) });
    expect(resA.ok).toBe(false);
    expect(missingCode).toHaveLength(1);
    expect(missingCode[0].event.kind).toBe("mcp_oauth_failed");
    expect(await mcpOauthTokens.get(db, server.id, uid)).toBeNull();

    const http400: Published[] = [];
    as.tokenResponse = { status: 400, body: { error: "invalid_grant" } };
    const flowB = makeFlow(http400);
    const { authorizeUrl: urlB } = await flowB.start(uid, server.id);
    const resB = await flowB.handleCallback({ state: stateOf(urlB), code: "auth-code-4" });
    expect(resB).toEqual({ uid, serverId: server.id, ok: false, reason: "oauth_failed" });
    expect(http400).toHaveLength(1);
    expect(await mcpOauthTokens.get(db, server.id, uid)).toBeNull();

    const redirected: Published[] = [];
    as.tokenResponse = { status: 302, location: "http://127.0.0.1:1/evil" };
    const flowC = makeFlow(redirected);
    const { authorizeUrl: urlC } = await flowC.start(uid, server.id);
    const resC = await flowC.handleCallback({ state: stateOf(urlC), code: "auth-code-5" });
    expect(resC.ok).toBe(false);
    expect(redirected).toHaveLength(1);
    expect(await mcpOauthTokens.get(db, server.id, uid)).toBeNull();

    const malformed: Published[] = [];
    as.tokenResponse = { status: 200, body: { token_type: "Bearer", refresh_token: "x" } };
    const flowD = makeFlow(malformed);
    const { authorizeUrl: urlD } = await flowD.start(uid, server.id);
    const resD = await flowD.handleCallback({ state: stateOf(urlD), code: "auth-code-6" });
    expect(resD.ok).toBe(false);
    expect(malformed).toHaveLength(1);
    expect(await mcpOauthTokens.get(db, server.id, uid)).toBeNull();

    as.tokenResponse = {
      status: 200,
      body: {
        access_token: FIXTURE_ACCESS_TOKEN,
        token_type: "Bearer",
        refresh_token: FIXTURE_REFRESH_TOKEN,
        expires_in: 3600,
      },
    };
  });

  it("start fails when the server row is missing or has no URL (ownership-scoped)", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    await expect(flow.start(uid, "01939a0f-0000-7000-8000-000000000001")).rejects.toThrow(/not found/);
    const server = await mcpServers.create(db, {
      userId: uid,
      name: `nourl-${Date.now().toString(36)}`,
      transport: "http",
      config: { type: "http" }, // no url
    });
    await expect(flow.start(uid, server.id)).rejects.toThrow(/no OAuth-discoverable URL/);
    expect(events).toHaveLength(0);
  });

  it("a custom redirectUri is honored on the authorize URL and the exchange", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events, "https://cb.example/oauth/cb");
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await flow.start(uid, server.id);
    expect(new URL(authorizeUrl).searchParams.get("redirect_uri")).toBe("https://cb.example/oauth/cb");
    const state = stateOf(authorizeUrl);
    const res = await flow.handleCallback({ state, code: "auth-code-7" });
    expect(res.ok).toBe(true);
    const tokenReq = as.requests.find(
      (r) => r.method === "POST" && (r.body ?? "").includes("code=auth-code-7"),
    )!;
    expect(new URLSearchParams(tokenReq.body!).get("redirect_uri")).toBe("https://cb.example/oauth/cb");
  });

  it("getAccessToken returns the sealed token while fresh, refreshes when expired and re-seals (old refresh token kept)", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await flow.start(uid, server.id);
    const state = stateOf(authorizeUrl);
    await flow.handleCallback({ state, code: "auth-code-8" });

    // Fresh: served from the seal, no refresh POST.
    const postsBefore = as.requests.filter((r) => r.method === "POST" && r.url === "/as/token").length;
    expect(await flow.getAccessToken(uid, server.id)).toBe(FIXTURE_ACCESS_TOKEN);
    expect(as.requests.filter((r) => r.method === "POST" && r.url === "/as/token").length).toBe(postsBefore);

    // Expired + refreshable: the refresh POST carries the sealed coordinates.
    await mcpOauthTokens.put(db, {
      userId: uid,
      serverId: server.id,
      tokensSealed: crypto.encrypt(
        JSON.stringify({
          accessToken: "stale-token",
          refreshToken: "refresh-me-1",
          expiresAt: Date.now() - 1_000,
          tokenUrl: `${as.origin}/as/token`,
          clientId: "dcr-client-1",
          clientSecret: "dcr-secret-1",
          resource: `${as.origin}/mcp`,
        }),
        `mcp_oauth_tokens:${server.id}`,
      ),
    });
    as.tokenResponse = { status: 200, body: { access_token: "fresh-token-2", token_type: "Bearer", expires_in: 3600 } }; // no refresh_token
    expect(await flow.getAccessToken(uid, server.id)).toBe("fresh-token-2");
    const refreshReq = as.requests.find(
      (r) => r.method === "POST" && (r.body ?? "").includes("refresh_token=refresh-me-1"),
    )!;
    const refreshBody = new URLSearchParams(refreshReq.body!);
    expect(refreshBody.get("grant_type")).toBe("refresh_token");
    expect(refreshBody.get("client_id")).toBe("dcr-client-1");
    expect(refreshBody.get("client_secret")).toBe("dcr-secret-1");
    expect(refreshBody.get("resource")).toBe(`${as.origin}/mcp`);

    // Re-sealed with the merged token set: the OLD refresh token was kept
    // (Dart parity: a refresh response may omit it).
    const resealed = JSON.parse(
      crypto.decrypt(
        (await mcpOauthTokens.get(db, server.id, uid))!.tokensSealed,
        `mcp_oauth_tokens:${server.id}`,
      ),
    ) as Record<string, unknown>;
    expect(resealed.accessToken).toBe("fresh-token-2");
    expect(resealed.refreshToken).toBe("refresh-me-1");
    expect(resealed.expiresAt as number).toBeGreaterThan(Date.now());

    as.tokenResponse = {
      status: 200,
      body: {
        access_token: FIXTURE_ACCESS_TOKEN,
        token_type: "Bearer",
        refresh_token: FIXTURE_REFRESH_TOKEN,
        expires_in: 3600,
      },
    };
  });

  it("getAccessToken: null when nothing is stored, expired without a refresh token, or the refresh fails", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    expect(await flow.getAccessToken(uid, server.id)).toBeNull();

    // Expired, no refresh token → null, and no POST is attempted.
    await mcpOauthTokens.put(db, {
      userId: uid,
      serverId: server.id,
      tokensSealed: crypto.encrypt(
        JSON.stringify({
          accessToken: "stale-token",
          refreshToken: null,
          expiresAt: Date.now() - 1_000,
          tokenUrl: `${as.origin}/as/token`,
          clientId: "dcr-client-1",
          clientSecret: null,
          resource: null,
        }),
        `mcp_oauth_tokens:${server.id}`,
      ),
    });
    const postsBefore = as.requests.filter((r) => r.method === "POST" && r.url === "/as/token").length;
    expect(await flow.getAccessToken(uid, server.id)).toBeNull();
    expect(as.requests.filter((r) => r.method === "POST" && r.url === "/as/token").length).toBe(postsBefore);

    // Refresh POST failing (400) → null (silent, Dart parity).
    await mcpOauthTokens.put(db, {
      userId: uid,
      serverId: server.id,
      tokensSealed: crypto.encrypt(
        JSON.stringify({
          accessToken: "stale-token",
          refreshToken: "refresh-me-2",
          expiresAt: Date.now() - 1_000,
          tokenUrl: `${as.origin}/as/token`,
          clientId: "dcr-client-1",
          clientSecret: null,
          resource: null,
        }),
        `mcp_oauth_tokens:${server.id}`,
      ),
    });
    as.tokenResponse = { status: 400, body: { error: "invalid_grant" } };
    expect(await flow.getAccessToken(uid, server.id)).toBeNull();
    as.tokenResponse = {
      status: 200,
      body: {
        access_token: FIXTURE_ACCESS_TOKEN,
        token_type: "Bearer",
        refresh_token: FIXTURE_REFRESH_TOKEN,
        expires_in: 3600,
      },
    };
  });

  it("disconnect removes the tokens row; a late callback for a deleted server cannot re-store tokens", async () => {
    const events: Published[] = [];
    const flow = makeFlow(events);
    const uid = await seedUser();
    const server = await seedServer(uid);
    const { authorizeUrl } = await flow.start(uid, server.id);
    const state = stateOf(authorizeUrl);
    await flow.handleCallback({ state, code: "auth-code-9" });
    expect(await mcpOauthTokens.get(db, server.id, uid)).not.toBeNull();

    await flow.disconnect(uid, server.id);
    expect(await mcpOauthTokens.get(db, server.id, uid)).toBeNull();
    expect(await flow.getAccessToken(uid, server.id)).toBeNull();

    // Stale-callback hardening: a flow started before the server row was
    // deleted completes nowhere — the exchange result is never stored.
    const events2: Published[] = [];
    const flow2 = makeFlow(events2);
    const uid2 = await seedUser();
    const server2 = await seedServer(uid2);
    const { authorizeUrl: url2 } = await flow2.start(uid2, server2.id);
    const state2 = stateOf(url2);
    await mcpServers.remove(db, server2.id, uid2);
    const res2 = await flow2.handleCallback({ state: state2, code: "auth-code-10" });
    expect(res2).toEqual({ uid: uid2, serverId: server2.id, ok: false, reason: "oauth_failed" });
    expect(events2[0].event.kind).toBe("mcp_oauth_failed");
    expect(await mcpOauthTokens.get(db, server2.id, uid2)).toBeNull();
  });
});
