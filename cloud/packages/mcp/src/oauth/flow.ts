/**
 * Server-side MCP OAuth PKCE flow — a port of the PKCE half of the Dart
 * app's `lib/core/mcp_service.dart` (begin/completeMcpOAuthAuthorization,
 * buildMcpAuthorizeUrl, exchangeMcpOAuthCode, refreshMcpOAuthToken,
 * disconnectAndForgetOAuth) onto Task 8's DB tables:
 *
 *   mcp_oauth_flows  — one-use, ten-minute authorization attempts, keyed by
 *                      the `state` param; the PKCE verifier (and the rare
 *                      DCR-issued client secret) are sealed under
 *                      recordId mcp_oauth_flows:{state}; the discovery
 *                      config rides the PLAIN config column (clientSecret
 *                      stripped — secrets are never plain columns).
 *   mcp_oauth_tokens — the live token set per server (UNIQUE(server_id)),
 *                      sealed under recordId mcp_oauth_tokens:{serverId}.
 *                      The sealed plaintext carries its own refresh
 *                      coordinates (tokenUrl/clientId/clientSecret/resource)
 *                      so a later refresh needs nothing but the seal.
 *
 * The sealed tokens are written through @ovid/db's repos (Task 8). The
 * workspace dependency @ovid/mcp → @ovid/db cannot be DECLARED in this wave
 * (the lockfile is frozen for parallel lanes), so the repos are loaded
 * lazily through a computed dynamic import and typed against local
 * structural interfaces (member-for-member the Task 8 signatures) — the
 * wave merger converts this to a real `import from "@ovid/db"`.
 *
 * SSRF discipline: every egress (discovery, token exchange, refresh) goes
 * through deps.fetchImpl — the caller's GuardedFetch; absent that, the
 * default createGuardedFetch(). Redirects are never followed.
 *
 * Callback HTML: flow.ts returns DATA ({ok, …}); the gateway routes (Task 15)
 * own the "Authorization complete — you can close this window." / failure
 * HTML rendering.
 */

import { createHash, randomBytes } from "node:crypto";
import type { EncryptedEnvelope, EnvelopeCrypto } from "../crypto.js";
import { createGuardedFetch, type GuardedFetch } from "../ssrf.js";
import { OAUTH_CLIENT_NAME, McpOAuthError, discoverOAuthConfig, requireOAuthEndpoint } from "./discovery.js";
import type { DiscoveredOAuthConfig } from "./discovery.js";

export const OAUTH_FLOW_TTL_MS = 600_000; // ten-minute, one-use attempt (Dart parity)
export const DEFAULT_MCP_REDIRECT_URI = "https://ovidsi.com/oauth/callback";

const TOKEN_TIMEOUT_MS = 30_000; // Dart parity: token request timeout
const EXPIRY_SKEW_MS = 30_000; // Dart parity: treat a token as expired 30s early

// ---------------------------------------------------------------------------
// PKCE (S256) — Dart parity: base64url, no padding
// ---------------------------------------------------------------------------

export function pkcePair(random: (n: number) => Buffer = randomBytes): {
  verifier: string;
  challenge: string;
} {
  const verifier = random(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier, "ascii").digest("base64url");
  return { verifier, challenge };
}

// ---------------------------------------------------------------------------
// Authorize URL (Dart buildMcpAuthorizeUrl)
// ---------------------------------------------------------------------------

export function buildAuthorizeUrl(
  cfg: DiscoveredOAuthConfig,
  o: { state: string; codeChallenge: string; redirectUri: string },
): string {
  if (typeof cfg.authorizationUrl !== "string" || cfg.authorizationUrl.trim() === "") {
    throw new McpOAuthError("discovery", "OAuth config has no authorization_url");
  }
  if (cfg.clientId === undefined || cfg.clientId === "") {
    throw new McpOAuthError("discovery", "OAuth config has no client_id");
  }
  const u = new URL(cfg.authorizationUrl.trim());
  // Pre-existing query params are preserved (first value wins — Dart
  // queryParameters), then the flow params override/append.
  const params = new Map<string, string>();
  for (const [k, v] of new URLSearchParams(u.search)) {
    if (!params.has(k)) params.set(k, v);
  }
  params.set("response_type", "code");
  params.set("client_id", cfg.clientId);
  if (o.redirectUri !== "") params.set("redirect_uri", o.redirectUri);
  if (cfg.scopes.length > 0) params.set("scope", cfg.scopes.join(" "));
  if (cfg.resource !== undefined && cfg.resource !== "") params.set("resource", cfg.resource);
  params.set("state", o.state);
  if (o.codeChallenge !== "") {
    params.set("code_challenge", o.codeChallenge);
    params.set("code_challenge_method", "S256");
  }
  // Manual encoding keeps spaces as %20 (Dart parity — URLSearchParams would
  // emit "+", which some authorization servers reject in scope/resource).
  u.search = [...params]
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
  return u.toString();
}

// ---------------------------------------------------------------------------
// System event publisher — the narrow structural subset of Task 10's
// UserSystemBus (that type itself is declared ONCE, in Task 10).
// ---------------------------------------------------------------------------

export interface SystemEventPublisher {
  publish(
    uid: string,
    event: {
      kind: string;
      requiresResponse?: boolean;
      payload: Record<string, unknown>;
    },
  ): Promise<void>;
}

// ---------------------------------------------------------------------------
// Task 8 repos — structural types + lazy computed dynamic import
// ---------------------------------------------------------------------------

/**
 * Opaque handle for @ovid/db's drizzle instance. Structural on purpose (see
 * the file header): the wave merger replaces this with @ovid/db's real `Db`
 * together with the loader below.
 */
type Db = object;

/** Structural mcp_servers row subset the flow reads. */
interface DbServerRow {
  id: string;
  userId: string;
  config: Record<string, unknown> | null;
}

/** Structural mcp_oauth_flows row (Task 8 McpOauthFlowRow). */
interface DbFlowRow {
  state: string;
  userId: string;
  serverId: string;
  verifierSealed: EncryptedEnvelope | null;
  config: Record<string, unknown> | null;
}

/** Structural mcp_oauth_tokens row (Task 8 McpOauthTokenRow). */
interface DbTokenRow {
  serverId: string;
  userId: string;
  tokensSealed: EncryptedEnvelope;
}

/**
 * Structural subset of @ovid/db's repos (Task 8) — member-for-member the
 * pinned signatures; only the namespaces the flow consumes.
 */
interface DbRepos {
  mcpServers: { get(db: Db, id: string, uid: string): Promise<DbServerRow | null> };
  mcpOauthFlows: {
    create(
      db: Db,
      input: {
        state: string;
        userId: string;
        serverId: string;
        verifierSealed?: EncryptedEnvelope | null;
        config?: Record<string, unknown> | null;
        expiresAt: Date;
      },
    ): Promise<void>;
    consume(db: Db, state: string): Promise<DbFlowRow | null>;
  };
  mcpOauthTokens: {
    put(db: Db, input: { userId: string; serverId: string; tokensSealed: EncryptedEnvelope }): Promise<void>;
    get(db: Db, serverId: string, uid: string): Promise<DbTokenRow | null>;
    remove(db: Db, serverId: string, uid: string): Promise<void>;
  };
}

/**
 * Candidates, in order:
 *  - `…/db/src/index.js` — resolves under vitest (vite-node maps .js → .ts
 *    source), always fresh;
 *  - `…/db/dist/index.js` — what Node ESM resolves from the BUILT
 *    dist/oauth/flow.js (the src candidate simply fails to resolve there).
 *
 * The computed (non-literal) specifier keeps tsc from pulling @ovid/db's
 * drizzle-typed surface into this package's program (its .d.ts wall of
 * optional-peer errors needs skipLibCheck we deliberately do not add).
 */
const DB_MODULE_CANDIDATES = ["../../../db/src/index.js", "../../../db/dist/index.js"];

let reposPromise: Promise<DbRepos> | undefined;

async function loadDbRepos(): Promise<DbRepos> {
  for (const spec of DB_MODULE_CANDIDATES) {
    try {
      const mod = (await import(spec)) as unknown as DbRepos;
      if (
        typeof mod.mcpOauthFlows?.create === "function" &&
        typeof mod.mcpOauthFlows?.consume === "function" &&
        typeof mod.mcpOauthTokens?.put === "function" &&
        typeof mod.mcpServers?.get === "function"
      ) {
        return mod;
      }
    } catch {
      // try the next candidate
    }
  }
  throw new Error(
    "@ovid/db (Task 8 repos) could not be loaded — build @ovid/db, or convert " +
      "the computed dynamic import in oauth/flow.ts to a declared workspace " +
      "dependency (wave-merger carry; see the file header)",
  );
}

function task8Repos(): Promise<DbRepos> {
  if (reposPromise === undefined) {
    // A failed load is retried on the next call, never cached as rejected.
    reposPromise = loadDbRepos().catch((e: unknown) => {
      reposPromise = undefined;
      throw e;
    });
  }
  return reposPromise;
}

// ---------------------------------------------------------------------------
// Sealed-store plumbing (EnvelopeCrypto, Task 8 recordId conventions)
// ---------------------------------------------------------------------------

/** The flow row's sealed plaintext (column verifier_sealed): the PKCE
 *  verifier plus the rare DCR-issued client secret — both secrets, both
 *  under the mcp_oauth_flows:{state} seal. */
interface SealedFlowSecrets {
  verifier: string;
  clientSecret: string | null;
}

/** The flow row's PLAIN config column: the discovery result minus every
 *  secret (clientSecret stripped). */
interface StoredFlowConfig {
  authorizationUrl: string;
  tokenUrl: string;
  registrationUrl?: string;
  clientId?: string;
  scopes: string[];
  resource?: string;
  issuer?: string;
  discovered: boolean;
  redirectUri: string;
}

/** The tokens row's sealed plaintext (recordId mcp_oauth_tokens:{serverId}):
 *  the token set plus its own refresh coordinates. */
interface SealedTokens {
  accessToken: string;
  refreshToken: string | null;
  /** Epoch ms. */
  expiresAt: number | null;
  tokenUrl: string;
  clientId: string;
  clientSecret: string | null;
  resource: string | null;
}

function seal(crypto: EnvelopeCrypto, value: unknown, recordId: string): EncryptedEnvelope {
  return crypto.encrypt(JSON.stringify(value), recordId);
}

function unseal<T>(crypto: EnvelopeCrypto, envelope: EncryptedEnvelope | null | undefined, recordId: string): T | null {
  if (envelope === null || envelope === undefined) return null;
  try {
    return JSON.parse(crypto.decrypt(envelope, recordId)) as T;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Token endpoint (Dart exchangeMcpOAuthCode / _postOAuth / fromTokenResponse)
// ---------------------------------------------------------------------------

async function postToken(
  fetcher: GuardedFetch,
  tokenUrl: string,
  fields: Record<string, string>,
): Promise<Record<string, unknown>> {
  const endpoint = requireOAuthEndpoint(tokenUrl.trim(), "Token endpoint");
  const res = await fetcher(endpoint.toString(), {
    method: "POST",
    redirect: "manual", // never followed — a redirect IS the failure (Dart)
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams(fields).toString(),
    signal: AbortSignal.timeout(TOKEN_TIMEOUT_MS),
  });
  if ([301, 302, 303, 307, 308].includes(res.status)) {
    throw new McpOAuthError("token", "OAuth token endpoint redirected");
  }
  if (res.status < 200 || res.status >= 300) {
    throw new McpOAuthError("token", `OAuth token exchange failed: HTTP ${res.status}`);
  }
  let body: unknown;
  try {
    body = await res.json();
  } catch {
    throw new McpOAuthError("token", "Malformed OAuth token response");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new McpOAuthError("token", "Malformed OAuth token response");
  }
  return body as Record<string, unknown>;
}

/** Port of McpOAuthToken.fromTokenResponse — strict field validation. */
function parseTokenResponse(j: Record<string, unknown>): {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;
} {
  const access = j["access_token"];
  const type = j["token_type"] ?? "Bearer";
  const expiresIn = j["expires_in"];
  if (
    typeof access !== "string" ||
    access === "" ||
    /[\x00-\x20\x7f]/.test(access) ||
    typeof type !== "string" ||
    type.toLowerCase() !== "bearer" ||
    (j["refresh_token"] !== undefined && typeof j["refresh_token"] !== "string") ||
    (expiresIn !== undefined &&
      (typeof expiresIn !== "number" || !Number.isInteger(expiresIn) || expiresIn < 0 || expiresIn > 315360000))
  ) {
    throw new McpOAuthError("token", "Malformed OAuth token response");
  }
  return {
    accessToken: access,
    refreshToken: typeof j["refresh_token"] === "string" && j["refresh_token"] !== "" ? j["refresh_token"] : null,
    expiresAt: typeof expiresIn === "number" ? Date.now() + expiresIn * 1000 : null,
  };
}

// ---------------------------------------------------------------------------
// The flow
// ---------------------------------------------------------------------------

export interface OAuthFlowDeps {
  db: Db;
  crypto: EnvelopeCrypto;
  systemBus: SystemEventPublisher;
  fetchImpl?: GuardedFetch;
  redirectUri?: string;
}

export interface OAuthFlow {
  /** Run discovery + DCR, persist a one-use flow row, return the authorize
   *  URL for the browser. Throws McpOAuthError on failure. */
  start(uid: string, serverId: string): Promise<{ authorizeUrl: string }>;
  /** Complete (or fail) the flow for a callback's params. Never throws —
   *  failures are {ok:false, reason:"oauth_failed"} plus an mcp_oauth_failed
   *  system event (uid/serverId are "" when the state is unknown/replayed). */
  handleCallback(params: {
    state: string;
    code?: string;
    error?: string;
    iss?: string;
  }): Promise<{ uid: string; serverId: string; ok: boolean; reason?: string }>;
  /** The live access token; refreshes via refresh_token when expired
   *  (single-flight per server). Null when nothing usable is stored. */
  getAccessToken(uid: string, serverId: string): Promise<string | null>;
  /** Forget ALL durable oauth material for the server (tokens row; the
   *  server-existence check in handleCallback blocks late callbacks for a
   *  deleted server). In-flight flow rows self-expire within the TTL. */
  disconnect(uid: string, serverId: string): Promise<void>;
}

/** The one failure reason the callback surface reports (the routes render
 *  generic failure copy; details live in the system event, sanitized). */
const OAUTH_FAILED = "oauth_failed";

/** Dart's redirect-URI sanity check on the config (server-side: the redirect
 *  is always an https/http web route — custom app schemes are the Android
 *  client's concern, not the gateway's). */
function validateRedirectUri(redirect: string): void {
  let u: URL;
  try {
    u = new URL(redirect);
  } catch {
    throw new McpOAuthError("discovery", "OAuth redirect URI is invalid");
  }
  const sp = new URLSearchParams(u.search);
  const repeated = [...new Set(sp.keys())].some((k) => sp.getAll(k).length > 1);
  const reserved = ["code", "state", "error", "iss"].some((k) => sp.has(k));
  if (
    (u.protocol !== "https:" && u.protocol !== "http:") ||
    u.username !== "" ||
    u.password !== "" ||
    u.hash !== "" ||
    repeated ||
    reserved
  ) {
    throw new McpOAuthError("discovery", "OAuth redirect URI is invalid");
  }
}

/** RFC 6750 error-code sanitization for event payloads (Dart parity). */
function sanitizeErrorCode(code: string): string {
  return /^[A-Za-z0-9_.\-]{1,64}$/.test(code) ? code : "error";
}

export function createOAuthFlow(deps: OAuthFlowDeps): OAuthFlow {
  const fetchImpl = deps.fetchImpl ?? createGuardedFetch();
  const redirectUri = deps.redirectUri ?? DEFAULT_MCP_REDIRECT_URI;
  // Single-flight refreshes per (uid, serverId) — Dart's _oauthRefreshes map.
  const refreshes = new Map<string, Promise<string | null>>();

  /** Notification only; a bus failure must never fail the flow's outcome. */
  async function notify(
    uid: string,
    kind: "mcp_oauth_completed" | "mcp_oauth_failed",
    payload: Record<string, unknown>,
  ): Promise<void> {
    try {
      await deps.systemBus.publish(uid, { kind, requiresResponse: false, payload });
    } catch {
      // swallowed — the tokens (or their absence) are the source of truth
    }
  }

  return {
    async start(uid: string, serverId: string): Promise<{ authorizeUrl: string }> {
      const repos = await task8Repos();
      const server = await repos.mcpServers.get(deps.db, serverId, uid);
      if (server === null) {
        throw new McpOAuthError("discovery", "MCP server not found for this user");
      }
      const serverUrl = server.config?.["url"];
      if (typeof serverUrl !== "string" || serverUrl.trim() === "") {
        throw new McpOAuthError("discovery", "MCP server has no OAuth-discoverable URL");
      }
      validateRedirectUri(redirectUri);

      // Without a stored usable config: full RFC 9728/8414 discovery + RFC
      // 7591 DCR (the server-side flow always registers — there is no static
      // oauth block to reuse here; that is the import path's owner, Task 14).
      const cfg = await discoverOAuthConfig({
        serverUrl,
        fetchImpl,
        register: true,
        redirectUri,
        clientName: OAUTH_CLIENT_NAME,
      });

      const state = randomBytes(32).toString("base64url");
      const { verifier, challenge } = pkcePair();
      const authorizeUrl = buildAuthorizeUrl(cfg, { state, codeChallenge: challenge, redirectUri });

      // Plain config column: everything EXCEPT the client secret.
      const { clientSecret, ...nonSecret } = cfg;
      const stored: StoredFlowConfig = { ...nonSecret, redirectUri };

      await repos.mcpOauthFlows.create(deps.db, {
        state,
        userId: uid,
        serverId,
        verifierSealed: seal(
          deps.crypto,
          { verifier, clientSecret: clientSecret ?? null } satisfies SealedFlowSecrets,
          `mcp_oauth_flows:${state}`,
        ),
        config: stored as unknown as Record<string, unknown>,
        expiresAt: new Date(Date.now() + OAUTH_FLOW_TTL_MS),
      });
      return { authorizeUrl };
    },

    async handleCallback(params): Promise<{ uid: string; serverId: string; ok: boolean; reason?: string }> {
      const repos = await task8Repos();
      // ATOMIC one-use consume (Task 8): exactly one concurrent caller can
      // win a state; replays and expired flows land here as null.
      const row = await repos.mcpOauthFlows.consume(deps.db, params.state);
      if (row === null) {
        return { uid: "", serverId: "", ok: false, reason: OAUTH_FAILED };
      }
      const uid = row.userId;
      const serverId = row.serverId;
      const fail = async (payload: Record<string, unknown> = {}): Promise<ReturnType<OAuthFlow["handleCallback"]>> => {
        await notify(uid, "mcp_oauth_failed", { serverId, ok: false, ...payload });
        return { uid, serverId, ok: false, reason: OAUTH_FAILED };
      };

      // The AS declined (error param) — one-use is spent, report and stop.
      if (params.error !== undefined) {
        return fail({ error: sanitizeErrorCode(params.error) });
      }

      try {
        // Stale-callback hardening: the server must still exist (and be
        // owned) — a sign-in for a deleted/disconnected server completes
        // nowhere.
        const server = await repos.mcpServers.get(deps.db, serverId, uid);
        if (server === null) {
          throw new McpOAuthError("callback", "MCP server no longer exists");
        }
        if (params.code === undefined || params.code === "") {
          throw new McpOAuthError("callback", "OAuth callback missing code");
        }
        const stored = row.config as (StoredFlowConfig | null);
        if (stored === null || stored.tokenUrl === undefined || stored.clientId === undefined) {
          throw new McpOAuthError("callback", "stored OAuth config unusable");
        }
        const secrets = unseal<SealedFlowSecrets>(
          deps.crypto,
          row.verifierSealed,
          `mcp_oauth_flows:${params.state}`,
        );
        if (secrets === null || secrets.verifier === "") {
          throw new McpOAuthError("callback", "stored PKCE verifier unreadable");
        }
        // RFC 9207 mix-up defence: a different authorization server answered.
        if (params.iss !== undefined && stored.issuer !== undefined && params.iss !== stored.issuer) {
          throw new McpOAuthError("callback", "OAuth callback issuer mismatch");
        }

        // Exchange — code_verifier from the seal, client_secret from the
        // seal, redirect_uri/resource from the stored config.
        const fields: Record<string, string> = {
          grant_type: "authorization_code",
          code: params.code,
          redirect_uri: stored.redirectUri,
          client_id: stored.clientId,
          ...(secrets.clientSecret !== null ? { client_secret: secrets.clientSecret } : {}),
          ...(stored.resource !== undefined && stored.resource !== ""
            ? { resource: stored.resource }
            : {}),
          code_verifier: secrets.verifier,
        };
        const response = await postToken(fetchImpl, stored.tokenUrl, fields);
        const parsed = parseTokenResponse(response);

        // Seal the token set WITH its refresh coordinates under
        // mcp_oauth_tokens:{serverId} (put = upsert on UNIQUE(server_id)).
        const tokens: SealedTokens = {
          accessToken: parsed.accessToken,
          refreshToken: parsed.refreshToken,
          expiresAt: parsed.expiresAt,
          tokenUrl: stored.tokenUrl,
          clientId: stored.clientId,
          clientSecret: secrets.clientSecret,
          resource: stored.resource ?? null,
        };
        await repos.mcpOauthTokens.put(deps.db, {
          userId: uid,
          serverId,
          tokensSealed: seal(deps.crypto, tokens, `mcp_oauth_tokens:${serverId}`),
        });
        await notify(uid, "mcp_oauth_completed", { serverId, ok: true });
        return { uid, serverId, ok: true };
      } catch {
        // Token/callback failures never leak detail to the route; the event
        // carries only {serverId, ok:false} (+error for the denied case).
        return fail();
      }
    },

    async getAccessToken(uid: string, serverId: string): Promise<string | null> {
      const repos = await task8Repos();
      const row = await repos.mcpOauthTokens.get(deps.db, serverId, uid);
      if (row === null) return null;
      const tokens = unseal<SealedTokens>(deps.crypto, row.tokensSealed, `mcp_oauth_tokens:${serverId}`);
      if (tokens === null || tokens.accessToken === "") return null;
      const expired =
        tokens.expiresAt !== null && Date.now() > tokens.expiresAt - EXPIRY_SKEW_MS;
      if (!expired) return tokens.accessToken;
      if (tokens.refreshToken === null) return null;
      // Hoisted: property narrowing does not survive into the closure below.
      const refreshToken = tokens.refreshToken;

      // Single-flight: parallel callers of a hot expired token share one
      // refresh POST (a rotating refresh token makes double-refresh fail).
      const key = `${uid}:${serverId}`;
      const inFlight = refreshes.get(key);
      if (inFlight !== undefined) return inFlight;
      const refresh = (async (): Promise<string | null> => {
        try {
          const response = await postToken(fetchImpl, tokens.tokenUrl, {
            grant_type: "refresh_token",
            refresh_token: refreshToken,
            client_id: tokens.clientId,
            ...(tokens.clientSecret !== null ? { client_secret: tokens.clientSecret } : {}),
            ...(tokens.resource !== null ? { resource: tokens.resource } : {}),
          });
          const parsed = parseTokenResponse(response);
          const merged: SealedTokens = {
            ...tokens,
            accessToken: parsed.accessToken,
            // A refresh response may omit the refresh token — keep the old one.
            refreshToken: parsed.refreshToken ?? tokens.refreshToken,
            expiresAt: parsed.expiresAt,
          };
          await repos.mcpOauthTokens.put(deps.db, {
            userId: uid,
            serverId,
            tokensSealed: seal(deps.crypto, merged, `mcp_oauth_tokens:${serverId}`),
          });
          return merged.accessToken;
        } catch {
          return null; // silent — the caller falls back to no-auth (Dart parity)
        }
      })();
      refreshes.set(key, refresh);
      try {
        return await refresh;
      } finally {
        refreshes.delete(key);
      }
    },

    async disconnect(uid: string, serverId: string): Promise<void> {
      const repos = await task8Repos();
      // The durable oauth material is the tokens row (ownership-scoped; a
      // deleted server row cascades it away too). Live flow rows are one-use
      // and expire within OAUTH_FLOW_TTL_MS, and handleCallback refuses to
      // store tokens for a server that no longer exists — a flows-invalidate
      // repo method in @ovid/db would close the remaining disconnect-without-
      // delete window (ledgered for the db lane).
      await repos.mcpOauthTokens.remove(deps.db, serverId, uid);
    },
  };
}
