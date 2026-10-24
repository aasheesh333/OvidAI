import { describe, expect, it } from "vitest";
import type { ProviderEgress } from "../egress/responseLimits.js";
import {
  McpOAuthError,
  OAUTH_CLIENT_NAME,
  discoverOAuthConfig,
  requireOAuthEndpoint,
  requestOAuth,
} from "./discovery.js";

// Unit-level discovery: a fake GuardedFetch (never touches the wire). The
// real guarded egress + a live 127.0.0.1 fixture AS are exercised end-to-end
// by flow.test.ts.

const HOST = "http://127.0.0.1:9463";
const REDIRECT = "https://ovidsi.com/oauth/callback";

interface Recorded {
  method: string;
  url: string;
  body?: string;
  contentType?: string;
  accept?: string;
}

/** URL-path-keyed fake GuardedFetch; unknown paths → 404 (absent metadata). */
function fakeFetch(routes: Record<string, unknown>, log: Recorded[]) {
  return async (url: string, init?: RequestInit): Promise<Response> => {
    const parsed = new URL(url);
    const key = `${parsed.origin}${parsed.pathname}`;
    const headers = (init?.headers ?? {}) as Record<string, string>;
    log.push({
      method: init?.method ?? "GET",
      url: key + parsed.search,
      body: typeof init?.body === "string" ? init.body : undefined,
      contentType: headers["content-type"],
      accept: headers.accept,
    });
    const hit = routes[key];
    if (hit === undefined) return new Response("not found", { status: 404 });
    if (typeof hit === "number") return new Response("boom", { status: hit });
    return Response.json(hit);
  };
}

/** The last POST recorded (the DCR request). */
function lastPost(log: Recorded[]): Recorded {
  return [...log].reverse().find((r) => r.method === "POST")!;
}

function urls(log: Recorded[]): string[] {
  return log.map((r) => r.url);
}

/** requireOAuthEndpoint throws synchronously — assert kind + message. */
function expectEndpointError(fn: () => unknown, what: string): void {
  let caught: unknown;
  try {
    fn();
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(McpOAuthError);
  expect((caught as McpOAuthError).kind).toBe("discovery");
  expect((caught as McpOAuthError).message).toContain(`${what} requires HTTPS`);
}

/** discoverOAuthConfig rejects — assert kind + message. */
async function expectDiscoveryError(
  promise: Promise<unknown>,
  kind: string,
  message: RegExp,
): Promise<void> {
  let caught: unknown;
  try {
    await promise;
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(McpOAuthError);
  expect((caught as McpOAuthError).kind).toBe(kind);
  expect((caught as McpOAuthError).message).toMatch(message);
}

const PRM = { resource: `${HOST}/api/mcp`, authorization_servers: [`${HOST}/as`] };
const ASM = {
  issuer: `${HOST}/as`,
  authorization_endpoint: `${HOST}/as/authorize`,
  token_endpoint: `${HOST}/as/token`,
  registration_endpoint: `${HOST}/as/register`,
  code_challenge_methods_supported: ["S256", "plain"],
};
const DCR = { client_id: "dcr-client-1", client_secret: "dcr-secret-1" };

describe("requireOAuthEndpoint", () => {
  it("accepts https and loopback http, returning the parsed URL", () => {
    expect(requireOAuthEndpoint("https://as.example/token", "Token endpoint").href).toBe(
      "https://as.example/token",
    );
    expect(requireOAuthEndpoint("http://127.0.0.1:9463/as", "X").href).toBe("http://127.0.0.1:9463/as");
    expect(requireOAuthEndpoint("http://localhost/as", "X").protocol).toBe("http:");
    // IPv6 loopback: brackets are stripped for the host comparison only.
    expect(requireOAuthEndpoint("http://[::1]/as", "X").protocol).toBe("http:");
  });

  it("rejects http non-loopback server URLs (before any fetch)", async () => {
    const log: Recorded[] = [];
    await expectDiscoveryError(
      discoverOAuthConfig({ serverUrl: "http://example.com/mcp", fetchImpl: fakeFetch({}, log) }),
      "discovery",
      /MCP server URL requires HTTPS/,
    );
    expect(log).toHaveLength(0);
  });

  it("rejects userinfo URLs", () => {
    expectEndpointError(() => requireOAuthEndpoint("https://alice:pw@as.example/token", "Token endpoint"), "Token endpoint");
    expectEndpointError(() => requireOAuthEndpoint("https://alice@as.example/token", "Token endpoint"), "Token endpoint");
  });

  it("rejects fragments and non-http(s) schemes", () => {
    expectEndpointError(() => requireOAuthEndpoint("https://as.example/t#frag", "X"), "X");
    expectEndpointError(() => requireOAuthEndpoint("ws://as.example/t", "X"), "X");
    expectEndpointError(() => requireOAuthEndpoint("not a url", "X"), "X");
  });
});

describe("discoverOAuthConfig", () => {
  it("PRM from WWW-Authenticate resource_metadata wins", async () => {
    const log: Recorded[] = [];
    const routes: Record<string, unknown> = {
      [`${HOST}/prm/metadata`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
      [`${HOST}/as/register`]: DCR,
    };
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      wwwAuthenticate: `Bearer realm="mcp", resource_metadata="${HOST}/prm/metadata", scope="read write"`,
      fetchImpl: fakeFetch(routes, log),
      redirectUri: REDIRECT,
      register: true,
    });
    expect(cfg.authorizationUrl).toBe(`${HOST}/as/authorize`);
    expect(cfg.tokenUrl).toBe(`${HOST}/as/token`);
    expect(cfg.registrationUrl).toBe(`${HOST}/as/register`);
    expect(cfg.clientId).toBe("dcr-client-1");
    expect(cfg.clientSecret).toBe("dcr-secret-1");
    expect(cfg.scopes).toEqual(["read", "write"]); // challenge scope wins
    expect(cfg.resource).toBe(`${HOST}/api/mcp`);
    expect(cfg.issuer).toBe(`${HOST}/as`);
    expect(cfg.discovered).toBe(true);
    // the challenge's resource_metadata was used; the default PRM well-knowns
    // were never fetched
    expect(urls(log)).toContain(`${HOST}/prm/metadata`);
    expect(urls(log).some((u) => u.includes("oauth-protected-resource"))).toBe(false);
    // DCR carried the default client name
    expect(JSON.parse(lastPost(log).body!).client_name).toBe(OAUTH_CLIENT_NAME);
  });

  it("path-aware well-known then root (register defaults to true)", async () => {
    const log: Recorded[] = [];
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
      [`${HOST}/as/register`]: DCR,
    };
    // no `register` flag: DCR runs by default (Dart parity — discovery
    // always dynamic-registers).
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      fetchImpl: fakeFetch(routes, log),
      redirectUri: REDIRECT,
    });
    expect(urls(log)).toEqual([
      `${HOST}/.well-known/oauth-protected-resource/api/mcp`,
      `${HOST}/.well-known/oauth-protected-resource`,
      `${HOST}/.well-known/oauth-authorization-server/as`,
      `${HOST}/as/register`,
    ]);
    expect(cfg.authorizationUrl).toBe(`${HOST}/as/authorize`);
    expect(cfg.tokenUrl).toBe(`${HOST}/as/token`);
    expect(cfg.resource).toBe(`${HOST}/api/mcp`);
    expect(cfg.clientId).toBe("dcr-client-1");
  });

  it("PRM naming a different origin → McpOAuthError", async () => {
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: {
        resource: "http://evil.example/api",
        authorization_servers: [`${HOST}/as`],
      },
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(routes, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "discovery",
      /different server/,
    );
  });

  it("PRM listing no authorization server → error", async () => {
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: { resource: `${HOST}/api/mcp` },
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(routes, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "discovery",
      /no authorization server/,
    );
  });

  it("ASM issuer mismatch → error", async () => {
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: { ...ASM, issuer: "http://other.example/as" },
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(routes, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "discovery",
      /issuer mismatch/,
    );
  });

  it("code_challenge_methods_supported without S256 → error; absent is fine", async () => {
    const noS256: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: { ...ASM, code_challenge_methods_supported: ["plain"] },
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(noS256, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "discovery",
      /PKCE/,
    );

    const absent: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: { ...ASM, code_challenge_methods_supported: undefined },
    };
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      fetchImpl: fakeFetch(absent, []),
      redirectUri: REDIRECT,
      register: false,
    });
    expect(cfg.tokenUrl).toBe(`${HOST}/as/token`);
  });

  it("2025-03-26 fallback endpoints when PRM+ASM missing", async () => {
    const log: Recorded[] = [];
    const routes: Record<string, unknown> = {
      [`${HOST}/register`]: DCR,
    };
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/mcp`,
      fetchImpl: fakeFetch(routes, log),
      redirectUri: REDIRECT,
      register: true,
    });
    expect(cfg.authorizationUrl).toBe(`${HOST}/authorize`);
    expect(cfg.tokenUrl).toBe(`${HOST}/token`);
    expect(cfg.registrationUrl).toBe(`${HOST}/register`);
    expect(cfg.clientId).toBe("dcr-client-1"); // DCR against the fallback /register
    expect(cfg.resource).toBe(`${HOST}/mcp`); // canonical resource from the server URL
    expect(cfg.issuer).toBeUndefined();
    expect(cfg.scopes).toEqual([]);
    expect(urls(log)).toEqual([
      `${HOST}/.well-known/oauth-protected-resource/mcp`,
      `${HOST}/.well-known/oauth-protected-resource`,
      `${HOST}/.well-known/oauth-authorization-server`,
      `${HOST}/.well-known/openid-configuration`,
      `${HOST}/register`,
    ]);
  });

  it("PRM present but ASM not found → error (no fallback)", async () => {
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(routes, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "discovery",
      /metadata not found/,
    );
  });

  it("ASM trailing .well-known/openid-configuration variant is tried", async () => {
    const log: Recorded[] = [];
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/as/.well-known/openid-configuration`]: ASM,
      [`${HOST}/as/register`]: DCR,
    };
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      fetchImpl: fakeFetch(routes, log),
      redirectUri: REDIRECT,
      register: true,
    });
    expect(cfg.tokenUrl).toBe(`${HOST}/as/token`);
    expect(cfg.issuer).toBe(`${HOST}/as`);
    expect(urls(log)).toEqual([
      `${HOST}/.well-known/oauth-protected-resource/api/mcp`,
      `${HOST}/.well-known/oauth-protected-resource`,
      `${HOST}/.well-known/oauth-authorization-server/as`,
      `${HOST}/.well-known/openid-configuration/as`,
      `${HOST}/as/.well-known/openid-configuration`,
      `${HOST}/as/register`,
    ]);
  });

  it("scopes come from the challenge scope, then PRM scopes_supported", async () => {
    // (a) the challenge scope wins over PRM scopes_supported
    const withChallenge: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: { ...PRM, scopes_supported: ["ignored-a", "ignored-b"] },
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
    };
    const a = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      wwwAuthenticate: 'Bearer scope="read write"',
      fetchImpl: fakeFetch(withChallenge, []),
      redirectUri: REDIRECT,
      register: false,
    });
    expect(a.scopes).toEqual(["read", "write"]);

    // (b) without a challenge scope, PRM scopes_supported is used
    const fromPrm: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: { ...PRM, scopes_supported: ["prm-a", "prm-b"] },
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
    };
    const b = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      fetchImpl: fakeFetch(fromPrm, []),
      redirectUri: REDIRECT,
      register: false,
    });
    expect(b.scopes).toEqual(["prm-a", "prm-b"]);
  });

  it("DCR posts a public-client registration and returns the clientId", async () => {
    const log: Recorded[] = [];
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: { ...PRM, scopes_supported: ["a", "b"] },
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
      [`${HOST}/as/register`]: DCR,
    };
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      fetchImpl: fakeFetch(routes, log),
      redirectUri: "https://cb.example/oauth/cb",
      clientName: "Custom Name",
      register: true,
    });
    const post = lastPost(log);
    expect(post.url).toBe(`${HOST}/as/register`);
    expect(post.contentType).toBe("application/json");
    expect(post.accept).toBe("application/json");
    expect(JSON.parse(post.body!)).toEqual({
      client_name: "Custom Name",
      redirect_uris: ["https://cb.example/oauth/cb"],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
      scope: "a b",
    });
    expect(cfg.clientId).toBe("dcr-client-1");
    expect(cfg.clientSecret).toBe("dcr-secret-1");
  });

  it("register:false skips DCR entirely", async () => {
    const log: Recorded[] = [];
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
    };
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      fetchImpl: fakeFetch(routes, log),
      redirectUri: REDIRECT,
      register: false,
    });
    expect(cfg.clientId).toBeUndefined();
    expect(cfg.registrationUrl).toBe(`${HOST}/as/register`);
    expect(log.some((r) => r.method === "POST")).toBe(false);
  });

  it("DCR failures surface as registration errors", async () => {
    const failed: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
      [`${HOST}/as/register`]: 400,
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(failed, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "registration",
      /Client registration failed \(HTTP 400\)/,
    );

    const noClientId: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
      [`${HOST}/as/register`]: { client_name: "nope" },
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(noClientId, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "registration",
      /no client_id/,
    );
  });

  it("register:true with no registration endpoint → error", async () => {
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
      [`${HOST}/.well-known/oauth-authorization-server/as`]: { ...ASM, registration_endpoint: undefined },
    };
    await expectDiscoveryError(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(routes, []),
        redirectUri: REDIRECT,
        register: true,
      }),
      "registration",
      /pre-registered OAuth client/,
    );
  });

  it("routes OAuth discovery through ProviderEgress instead of legacy fetch", async () => {
    const requests: Parameters<ProviderEgress["request"]>[0][] = [];
    const providerEgress: ProviderEgress = {
      async request(req) {
        requests.push(req);
        const key = `${req.url.origin}${req.url.pathname}`;
        const value = key === `${HOST}/.well-known/oauth-protected-resource`
          ? PRM
          : key === `${HOST}/.well-known/oauth-authorization-server/as`
            ? ASM
            : undefined;
        const response = value === undefined
          ? new Response("not found", { status: 404 })
          : Response.json(value);
        return {
          status: response.status,
          headers: response.headers,
          body: response.body!,
          origin: req.url,
          remoteAddress: "192.0.2.20",
        };
      },
      async close() {},
    };
    const cfg = await discoverOAuthConfig({
      serverUrl: `${HOST}/api/mcp`,
      providerEgress,
      originKey: "oauth-test",
      fetchImpl: async () => { throw new Error("legacy fetch must not run"); },
      redirectUri: REDIRECT,
      register: false,
    });
    expect(cfg.tokenUrl).toBe(`${HOST}/as/token`);
    expect(requests.length).toBeGreaterThan(0);
    expect(requests.every((req) => req.originKey === "oauth-test" && req.redirect === "deny")).toBe(true);
  });

  it("cancels OAuth response bodies when header validation fails in either transport mode", async () => {
    for (const mode of ["legacy", "egress"] as const) {
      let cancelled = 0;
      const body = new ReadableStream<Uint8Array>({
        pull() {},
        cancel() { cancelled++; },
      });
      const response = new Response(body, {
        status: 200,
        headers: { "content-type": "application/json", "x-overflow": "x".repeat(200) },
      });
      const limits = {
        connectMs: 100,
        headersMs: 100,
        idleMs: 100,
        totalMs: 1_000,
        maxRedirects: 0,
        headerBytes: 32,
        responseBytes: 1_024,
        decompressedBytes: 1_024,
      };
      const providerEgress: ProviderEgress = {
        async request(req) {
          return {
            status: response.status,
            headers: response.headers,
            body: response.body!,
            origin: req.url,
            remoteAddress: "192.0.2.30",
          };
        },
        async close() {},
      };
      await expect(requestOAuth(
        mode === "egress" ? { providerEgress, limits } : { fetchImpl: async () => response, limits },
        new URL(`${HOST}/token`),
        { method: "GET", headers: { accept: "application/json" } },
      )).rejects.toThrow(/header_bytes/);
      expect(cancelled, mode).toBe(1);
    }
  });

  it("cancels discovery and registration bodies on header-cap failures", async () => {
    for (const stage of ["discovery", "registration"] as const) {
      let cancelled = 0;
      const oversized = async (): Promise<Response> => new Response(
        new ReadableStream<Uint8Array>({ pull() {}, cancel() { cancelled++; } }),
        { status: 200, headers: { "content-type": "application/json", "x-overflow": "x".repeat(200) } },
      );
      const routes: Record<string, unknown> = {
        [`${HOST}/.well-known/oauth-protected-resource`]: PRM,
        [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
      };
      const ordinary = fakeFetch(routes, []);
      await expect(discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: async (url, init) => {
          const parsed = new URL(url);
          if (stage === "discovery" || parsed.pathname === "/as/register") return oversized();
          return ordinary(url, init);
        },
        redirectUri: REDIRECT,
        register: true,
        limits: {
          connectMs: 100,
          headersMs: 100,
          idleMs: 100,
          totalMs: 1_000,
          maxRedirects: 0,
          headerBytes: 64,
          responseBytes: 1_024,
          decompressedBytes: 1_024,
        },
      })).rejects.toThrow(McpOAuthError);
      expect(cancelled, stage).toBe(1);
    }
  });

  it("bounds metadata bytes before JSON parsing", async () => {
    const log: Recorded[] = [];
    const routes: Record<string, unknown> = {
      [`${HOST}/.well-known/oauth-protected-resource`]: { ...PRM, padding: "x".repeat(2_000) },
      [`${HOST}/.well-known/oauth-authorization-server/as`]: ASM,
    };
    await expect(
      discoverOAuthConfig({
        serverUrl: `${HOST}/api/mcp`,
        fetchImpl: fakeFetch(routes, log),
        redirectUri: REDIRECT,
        register: false,
        limits: {
          connectMs: 100,
          headersMs: 100,
          idleMs: 100,
          totalMs: 1_000,
          maxRedirects: 0,
          headerBytes: 1_024,
          responseBytes: 64,
          decompressedBytes: 64,
        },
      }),
    ).rejects.toThrow(McpOAuthError);
    expect(log).toHaveLength(2);
    expect(log[1].url).toBe(`${HOST}/.well-known/oauth-protected-resource`);
  });
});
