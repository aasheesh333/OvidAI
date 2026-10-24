/**
 * MCP OAuth discovery — a port of the Dart app's
 * `lib/core/mcp_oauth_discovery.dart` (MCP authorization spec 2025-06-18):
 *
 *  1. RFC 9728 protected-resource metadata — from the `WWW-Authenticate`
 *     challenge's `resource_metadata`, else the
 *     `/.well-known/oauth-protected-resource` path-aware then root location.
 *  2. RFC 8414 authorization-server metadata for the first listed
 *     authorization server (path-aware oauth-authorization-server, then
 *     openid-configuration, then the trailing well-known variant). Servers
 *     without protected-resource metadata fall back to the 2025-03-26 rule:
 *     the MCP origin IS the authorization server with `/authorize`, `/token`
 *     and `/register` as defaults.
 *  3. RFC 7591 dynamic client registration as a public client
 *     (`token_endpoint_auth_method: none`, PKCE S256).
 *
 * The returned config carries the RFC 8707 `resource` indicator, which the
 * flow sends on the authorize, token and refresh requests.
 *
 * SSRF discipline: EVERY request goes through a GuardedFetch (Task 3) — the
 * caller injects its guarded egress (with the right allowed ports); when none
 * is injected the default createGuardedFetch() applies, so this module never
 * raw-fetches. Redirects are NOT followed (Dart parity): a 3xx on a metadata
 * candidate counts as absent, a 3xx from registration is a failure.
 */

import {
  assertBoundedHeadersOrCancel,
  DEFAULT_EGRESS_LIMITS,
  egressResponseFromDecodedFetch,
  readBoundedBody,
  type EgressLimits,
  type EgressResponse,
  type ProviderEgress,
} from "../egress/responseLimits.js";
import { createGuardedFetch, type GuardedFetch } from "../ssrf.js";

export interface DiscoveredOAuthConfig {
  authorizationUrl: string;
  tokenUrl: string;
  registrationUrl?: string;
  clientId?: string;
  clientSecret?: string;
  scopes: string[];
  /** RFC 8707 resource indicator (the MCP server's canonical URL). */
  resource?: string;
  /** Authorization-server issuer (RFC 9207 `iss` callback check). */
  issuer?: string;
  /** True when this config came from discovery + DCR rather than a static block. */
  discovered: boolean;
}

/** Typed OAuth failure. Kinds: discovery (metadata), registration (DCR),
 *  token (exchange/refresh), callback (callback validation). Messages never
 *  carry callback secrets. */
export class McpOAuthError extends Error {
  constructor(
    readonly kind: "discovery" | "registration" | "token" | "callback",
    message: string,
  ) {
    super(message);
    this.name = "McpOAuthError";
  }
}

export const OAUTH_CLIENT_NAME = "Ovid";

const REQUEST_TIMEOUT_MS = 15_000; // Dart parity: per-request timeout

/** The only loopback hosts http (not https) may target (Dart parity). */
const LOOPBACK_HTTP_HOSTS = new Set(["127.0.0.1", "::1", "localhost"]);

/**
 * HTTPS (or loopback HTTP for local development) without user info or a
 * fragment — the only destinations OAuth metadata, registration and token
 * requests may go to.
 */
export function requireOAuthEndpoint(value: string, what: string): URL {
  let uri: URL | null = null;
  const raw = value ?? "";
  try {
    uri = new URL(raw);
  } catch {
    uri = null;
  }
  const host = uri ? uri.hostname.replace(/^\[/, "").replace(/\]$/, "") : "";
  if (
    uri === null ||
    host === "" ||
    uri.username !== "" ||
    uri.password !== "" ||
    uri.hash !== "" ||
    /^https?:\/\/[^/?#]*@/i.test(raw) ||
    (uri.protocol !== "https:" &&
      !(uri.protocol === "http:" && LOOPBACK_HTTP_HOSTS.has(host)))
  ) {
    throw new McpOAuthError("discovery", `${what} requires HTTPS (or loopback HTTP)`);
  }
  return uri;
}

// ---------------------------------------------------------------------------
// Bearer challenge parsing (RFC 6750 §3 + RFC 9728 §5.1 resource_metadata)
// ---------------------------------------------------------------------------

interface BearerChallenge {
  resourceMetadata?: string;
  scope?: string;
}

/** Parse the Bearer challenge out of a WWW-Authenticate header value; null
 *  when the header carries no Bearer challenge. Port of McpBearerChallenge.parse. */
function parseBearerChallenge(header: string | null | undefined): BearerChallenge | null {
  if (header === null || header === undefined || header.trim() === "") return null;
  const scheme = /(?:^|,)\s*Bearer\b/i.exec(header);
  if (scheme === null) return null;
  const rest = header.slice(scheme.index + scheme[0].length);
  const params: Record<string, string> = {};
  // Sticky regex = Dart's matchAsPrefix: anchored at the running offset.
  const param = /\s*,?\s*([A-Za-z0-9_\-]+)\s*=\s*("(?:[^"\\]|\\.)*"|[^\s,]+)/y;
  let offset = 0;
  while (offset < rest.length) {
    param.lastIndex = offset;
    const m = param.exec(rest);
    if (m === null) break; // next token is not name=value (a new challenge scheme)
    const name = m[1].toLowerCase();
    let value = m[2];
    if (value.startsWith('"')) {
      value = value.slice(1, -1).replace(/\\(.)/g, "$1");
    }
    if (!(name in params)) params[name] = value; // putIfAbsent
    offset = param.lastIndex;
  }
  return { resourceMetadata: params.resource_metadata, scope: params.scope };
}

// ---------------------------------------------------------------------------
// URL helpers (Dart parity)
// ---------------------------------------------------------------------------

function trimSlash(s: string): string {
  return s.endsWith("/") ? s.slice(0, s.length - 1) : s;
}

/** RFC 8707 resource indicator: the server URL without query or fragment. */
function canonicalResource(server: URL): string {
  return `${server.origin}${server.pathname}`;
}

/** scheme://host:port comparison key (default ports normalized, like Dart's
 *  Uri.port) — the "declared resource matches the server origin" check. */
function originKey(u: URL): string {
  const port = u.port === "" ? (u.protocol === "https:" ? "443" : "80") : u.port;
  return `${u.protocol}//${u.hostname.replace(/^\[/, "").replace(/\]$/, "").toLowerCase()}:${port}`;
}

/** RFC 8414 §3 / RFC 9728 §3: insert the well-known segment between the host
 *  and the (path-aware) resource or issuer path. */
function wellKnown(base: URL, name: string, path: string): string {
  return `${base.origin}/.well-known/${name}${trimSlash(path)}`;
}

// ---------------------------------------------------------------------------
// Fetch helpers
// ---------------------------------------------------------------------------

export interface OAuthNetworkOptions {
  fetchImpl?: GuardedFetch;
  providerEgress?: ProviderEgress;
  originKey?: string;
  limits?: EgressLimits;
}

function oauthLimits(network: OAuthNetworkOptions): EgressLimits {
  return network.limits ?? {
    ...DEFAULT_EGRESS_LIMITS,
    totalMs: REQUEST_TIMEOUT_MS,
    idleMs: REQUEST_TIMEOUT_MS,
    headersMs: REQUEST_TIMEOUT_MS,
  };
}

export async function requestOAuth(
  network: OAuthNetworkOptions,
  url: URL,
  init: {
    method: "GET" | "POST";
    headers: Record<string, string>;
    body?: string;
    secretValues?: readonly string[];
  },
): Promise<EgressResponse> {
  const limits = oauthLimits(network);
  const signal = AbortSignal.timeout(limits.totalMs);
  let response: EgressResponse;
  if (network.providerEgress !== undefined) {
    response = await network.providerEgress.request({
      originKey: network.originKey ?? "oauth",
      url,
      method: init.method,
      headers: init.headers,
      ...(init.body === undefined ? {} : { body: new TextEncoder().encode(init.body) }),
      secretValues: init.secretValues ?? [],
      privileged: true,
      redirect: "deny",
      limits,
      signal,
    });
  } else {
    const fetcher = network.fetchImpl ?? createGuardedFetch();
    const legacy = await fetcher(url.toString(), {
      method: init.method,
      redirect: "manual",
      headers: init.headers,
      ...(init.body === undefined ? {} : { body: init.body }),
      signal,
    });
    response = egressResponseFromDecodedFetch(legacy, url);
  }
  await assertBoundedHeadersOrCancel(response, limits);
  return response;
}

async function getJson(
  network: OAuthNetworkOptions,
  url: string,
): Promise<Record<string, unknown> | null> {
  const endpoint = requireOAuthEndpoint(url, "OAuth metadata URL");
  const response = await requestOAuth(network, endpoint, {
    method: "GET",
    headers: { accept: "application/json" },
  });
  if (response.status !== 200) {
    await response.body.cancel().catch(() => {});
    return null;
  }
  const bytes = await readBoundedBody(response, oauthLimits(network));
  try {
    const decoded: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    return typeof decoded === "object" && decoded !== null && !Array.isArray(decoded)
      ? (decoded as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

interface RegistrationResult {
  clientId: string;
  clientSecret: string | null;
}

/** RFC 7591 dynamic client registration as a PUBLIC client. */
async function dynamicRegister(
  network: OAuthNetworkOptions,
  endpoint: URL,
  opts: { redirectUri: string; scopes: string[]; clientName: string },
): Promise<RegistrationResult> {
  const response = await requestOAuth(network, endpoint, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      client_name: opts.clientName,
      redirect_uris: [opts.redirectUri],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
      ...(opts.scopes.length > 0 ? { scope: opts.scopes.join(" ") } : {}),
    }),
  });
  if (response.status < 200 || response.status >= 300) {
    await response.body.cancel().catch(() => {});
    throw new McpOAuthError("registration", `Client registration failed (HTTP ${response.status})`);
  }
  let decoded: Record<string, unknown> | null = null;
  try {
    const bytes = await readBoundedBody(response, oauthLimits(network));
    const body: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    decoded = typeof body === "object" && body !== null && !Array.isArray(body)
      ? (body as Record<string, unknown>)
      : null;
  } catch {
    decoded = null;
  }
  const clientId = decoded?.client_id;
  if (typeof clientId !== "string" || clientId === "") {
    throw new McpOAuthError("registration", "Client registration returned no client_id");
  }
  const secret = decoded?.client_secret;
  return {
    clientId,
    clientSecret: typeof secret === "string" && secret !== "" ? secret : null,
  };
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

export interface DiscoverOAuthOptions extends OAuthNetworkOptions {
  serverUrl: string;
  /** The 401's WWW-Authenticate header (its resource_metadata/scope hints). */
  wwwAuthenticate?: string | null;
  /** Run RFC 7591 DCR (default true — Dart parity: discovery always registers). */
  register?: boolean;
  redirectUri?: string;
  clientName?: string;
}

function isTimeout(e: unknown): boolean {
  return e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError");
}

export async function discoverOAuthConfig(
  opts: DiscoverOAuthOptions,
): Promise<DiscoveredOAuthConfig> {
  const network: OAuthNetworkOptions = {
    fetchImpl: opts.fetchImpl ?? (opts.providerEgress === undefined ? createGuardedFetch() : undefined),
    providerEgress: opts.providerEgress,
    originKey: opts.originKey,
    limits: opts.limits,
  };
  const clientName = opts.clientName ?? OAUTH_CLIENT_NAME;
  const doRegister = opts.register !== false;

  try {
    const server = requireOAuthEndpoint(opts.serverUrl, "MCP server URL");
    const challenge = parseBearerChallenge(opts.wwwAuthenticate);

    // ── 1. Protected-resource metadata (RFC 9728) ────────────────────────
    const prmCandidates: string[] = [];
    if ((challenge?.resourceMetadata ?? "") !== "") {
      prmCandidates.push(
        requireOAuthEndpoint(challenge!.resourceMetadata!, "Resource metadata URL").toString(),
      );
    } else {
      if (server.pathname !== "/" && server.pathname !== "") {
        prmCandidates.push(wellKnown(server, "oauth-protected-resource", server.pathname));
      }
      prmCandidates.push(wellKnown(server, "oauth-protected-resource", ""));
    }
    let prm: Record<string, unknown> | null = null;
    for (const candidate of prmCandidates) {
      prm = await getJson(network, candidate);
      if (prm !== null) break;
    }

    let resource = canonicalResource(server);
    let issuer: URL;
    if (prm !== null) {
      const declared = prm["resource"];
      if (typeof declared === "string" && declared !== "") {
        let declaredUri: URL | null = null;
        try {
          declaredUri = new URL(declared);
        } catch {
          declaredUri = null;
        }
        if (
          declaredUri === null ||
          declaredUri.protocol !== server.protocol ||
          originKey(declaredUri) !== originKey(server)
        ) {
          throw new McpOAuthError("discovery", "Resource metadata names a different server");
        }
        resource = declared;
      }
      const servers = prm["authorization_servers"];
      const first = Array.isArray(servers) && servers.length > 0 ? servers[0] : null;
      if (typeof first !== "string" || first === "") {
        throw new McpOAuthError("discovery", "Resource metadata lists no authorization server");
      }
      issuer = requireOAuthEndpoint(first, "Authorization server");
    } else {
      // No PRM: the MCP origin is the authorization server.
      issuer = new URL(server.origin);
    }

    // ── 2. Authorization-server metadata (RFC 8414 / OIDC) ───────────────
    const issuerPath = issuer.pathname === "/" ? "" : issuer.pathname;
    const asmCandidates: string[] = [
      wellKnown(issuer, "oauth-authorization-server", issuerPath),
      wellKnown(issuer, "openid-configuration", issuerPath),
      ...(issuerPath !== ""
        ? [`${issuer.origin}${trimSlash(issuerPath)}/.well-known/openid-configuration`]
        : []),
    ];
    let asm: Record<string, unknown> | null = null;
    for (const candidate of asmCandidates) {
      asm = await getJson(network, candidate);
      if (asm !== null) break;
    }

    let authorizationEndpoint: string | null = null;
    let tokenEndpoint: string | null = null;
    let registrationEndpoint: string | null = null;
    let issuerId: string | null = null;
    if (asm !== null) {
      const declaredIssuer = asm["issuer"];
      if (
        typeof declaredIssuer === "string" &&
        declaredIssuer !== "" &&
        trimSlash(declaredIssuer) !== trimSlash(issuer.toString())
      ) {
        throw new McpOAuthError("discovery", "Authorization server metadata issuer mismatch");
      }
      if (typeof declaredIssuer === "string" && declaredIssuer !== "") {
        issuerId = declaredIssuer;
      }
      const auth = asm["authorization_endpoint"];
      authorizationEndpoint = typeof auth === "string" ? auth : null;
      const token = asm["token_endpoint"];
      tokenEndpoint = typeof token === "string" ? token : null;
      const reg = asm["registration_endpoint"];
      registrationEndpoint = typeof reg === "string" ? reg : null;
      const methods = asm["code_challenge_methods_supported"];
      if (Array.isArray(methods) && !methods.includes("S256")) {
        throw new McpOAuthError("discovery", "Authorization server does not support PKCE (S256)");
      }
    } else if (prm === null) {
      // 2025-03-26 fallback: default endpoints on the MCP origin.
      authorizationEndpoint = `${issuer.origin}/authorize`;
      tokenEndpoint = `${issuer.origin}/token`;
      registrationEndpoint = `${issuer.origin}/register`;
    } else {
      throw new McpOAuthError("discovery", "Authorization server metadata not found");
    }
    requireOAuthEndpoint(authorizationEndpoint ?? "", "Authorize endpoint");
    requireOAuthEndpoint(tokenEndpoint ?? "", "Token endpoint");

    const scopes: string[] = [];
    if (challenge?.scope !== undefined) {
      scopes.push(...challenge.scope.split(/\s+/).filter((s) => s !== ""));
    }
    if (scopes.length === 0 && Array.isArray(prm?.["scopes_supported"])) {
      for (const s of prm["scopes_supported"] as unknown[]) {
        if (typeof s === "string" && s !== "") scopes.push(s);
      }
    }

    // ── 3. Dynamic client registration (RFC 7591) ────────────────────────
    let clientId: string | undefined;
    let clientSecret: string | undefined;
    if (doRegister) {
      if (registrationEndpoint === null || registrationEndpoint === "") {
        throw new McpOAuthError(
          "registration",
          'This server needs a pre-registered OAuth client — add an "oauth" block with a client_id to its config',
        );
      }
      if (opts.redirectUri === undefined || opts.redirectUri === "") {
        throw new McpOAuthError("registration", "redirectUri is required for dynamic client registration");
      }
      const registration = await dynamicRegister(
        network,
        requireOAuthEndpoint(registrationEndpoint, "Registration endpoint"),
        {
          redirectUri: opts.redirectUri ?? "",
          scopes,
          clientName,
        },
      );
      clientId = registration.clientId;
      clientSecret = registration.clientSecret ?? undefined;
    }

    return {
      authorizationUrl: authorizationEndpoint!,
      tokenUrl: tokenEndpoint!,
      registrationUrl: registrationEndpoint ?? undefined,
      clientId,
      clientSecret,
      scopes,
      resource,
      issuer: issuerId ?? undefined,
      discovered: true,
    };
  } catch (e) {
    if (e instanceof McpOAuthError) throw e;
    if (isTimeout(e)) {
      throw new McpOAuthError("discovery", "The sign-in server did not respond in time");
    }
    // Any unexpected failure (network, SSRF refusal, JSON…) — one generic
    // discovery error, no underlying detail leaked.
    throw new McpOAuthError("discovery", "Could not discover how to sign in to this server");
  }
}
