import {
  DEFAULT_EGRESS_LIMITS,
  assertBoundedHeadersOrCancel,
  egressResponseFromDecodedFetch,
  readOAuthBody,
  requireOAuthEndpoint,
  type EnvelopeCrypto,
  type GuardedFetch,
  type HealthRefreshInput,
  type HealthRefreshOutcome,
} from "@ovid/mcp";
import { mcpOauthTokens, mcpServers as serverRepo, type Db } from "@ovid/db";

/** The sealed format already owned by oauth/flow.ts; no OAuth file is modified. */
interface SealedTokenMaterial {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;
  tokenUrl: string;
  clientId: string;
  clientSecret: string | null;
  resource: string | null;
}

export interface ConnectionHealthOAuthIdentity {
  connectionId: string;
  userId: string;
}

export type ConnectionHealthOAuthRefresher = (
  identity: ConnectionHealthOAuthIdentity,
  input: HealthRefreshInput,
) => Promise<HealthRefreshOutcome>;

export interface ConnectionHealthOAuthDeps {
  db: Db;
  crypto: EnvelopeCrypto;
  /** Production uses a real SSRF-guarded fetch, never globalThis.fetch. */
  fetchImpl: GuardedFetch;
  now?(): Date;
}

function tokenMaterial(value: unknown): SealedTokenMaterial | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  if (typeof candidate.accessToken !== "string" ||
      typeof candidate.refreshToken !== "string" || candidate.refreshToken === "" ||
      typeof candidate.tokenUrl !== "string" || typeof candidate.clientId !== "string" ||
      (candidate.expiresAt !== null && typeof candidate.expiresAt !== "number") ||
      (candidate.clientSecret !== null && typeof candidate.clientSecret !== "string") ||
      (candidate.resource !== null && typeof candidate.resource !== "string")) return null;
  // Every field was validated above; the record is structurally the material.
  return candidate as unknown as SealedTokenMaterial;
}

const OAUTH_REFRESH_HEADER_TIMEOUT_MS = 30_000;

async function fetchWithHeaderDeadline(
  fetchImpl: GuardedFetch,
  url: string,
  init: RequestInit,
  parent: AbortSignal,
): Promise<{ response: Response; signal: AbortSignal; cleanup(): void }> {
  const controller = new AbortController();
  const abort = () => controller.abort(parent.reason);
  const onAbort = () => controller.abort(parent.reason);
  if (parent.aborted) abort();
  else parent.addEventListener("abort", onAbort, { once: true });
  const timer = setTimeout(() => controller.abort("oauth_refresh_header_timeout"), OAUTH_REFRESH_HEADER_TIMEOUT_MS);
  timer.unref?.();
  const aborted = new Promise<never>((_resolve, reject) => {
    if (controller.signal.aborted) reject(controller.signal.reason);
    else controller.signal.addEventListener("abort", () => reject(controller.signal.reason), { once: true });
  });
  const cleanup = () => {
    clearTimeout(timer);
    parent.removeEventListener("abort", onAbort);
  };
  try {
    if (controller.signal.aborted) throw new Error("oauth_refresh_aborted");
    const response = await Promise.race([
      fetchImpl(url, { ...init, signal: controller.signal }),
      aborted,
    ]);
    // Caller owns cleanup through body consumption and token-write settlement.
    return { response, signal: controller.signal, cleanup };
  } catch (error) {
    cleanup();
    throw error;
  }
}

function parsedAccessToken(body: Record<string, unknown>, now: Date): {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;
} | null {
  const accessToken = body.access_token;
  const tokenType = body.token_type ?? "Bearer";
  const expiresIn = body.expires_in;
  if (typeof accessToken !== "string" || accessToken === "" || /[\x00-\x20\x7f]/.test(accessToken) ||
      typeof tokenType !== "string" || tokenType.toLowerCase() !== "bearer" ||
      (body.refresh_token !== undefined && typeof body.refresh_token !== "string") ||
      (expiresIn !== undefined &&
        (typeof expiresIn !== "number" || !Number.isInteger(expiresIn) || expiresIn < 0 || expiresIn > 315_360_000))) {
    return null;
  }
  return {
    accessToken,
    refreshToken: typeof body.refresh_token === "string" && body.refresh_token !== ""
      ? body.refresh_token
      : null,
    expiresAt: typeof expiresIn === "number" ? now.getTime() + expiresIn * 1000 : null,
  };
}

/**
 * Real refresh adapter with caller-signal cancellation and bounded responses.
 * It deliberately does NOT call OAuthFlow.getAccessToken or mcpOauthTokens.put:
 * both can write outside this lifecycle's config/disconnect fence.
 */
export function createConnectionHealthOAuthRefresher(
  deps: ConnectionHealthOAuthDeps,
): ConnectionHealthOAuthRefresher {
  const now = deps.now ?? (() => new Date());
  return async (identity, input) => {
    try {
      if (input.signal.aborted) return { status: "failed", reason: "unavailable" };
      const row = await mcpOauthTokens.get(deps.db, identity.connectionId, identity.userId);
      if (row === null || input.signal.aborted) return { status: "failed", reason: "unauthorized" };
      let material: SealedTokenMaterial | null;
      try {
        material = tokenMaterial(JSON.parse(deps.crypto.decrypt(
          row.tokensSealed,
          `mcp_oauth_tokens:${identity.connectionId}`,
        )));
      } catch {
        return { status: "failed", reason: "unauthorized" };
      }
      if (material === null || material.refreshToken === null) {
        return { status: "failed", reason: "unauthorized" };
      }
      // Cross-process disconnect/config fence at the final boundary before
      // network dispatch. The parent row is checked again after token decrypt.
      const current = await serverRepo.get(deps.db, identity.connectionId, identity.userId);
      if (current === null || !current.enabled ||
          current.configVersion !== input.expected.configVersion ||
          current.disconnectGeneration !== input.expected.disconnectGeneration ||
          current.authState === "revoked" || current.healthState === "revoked" || input.signal.aborted) {
        return { status: "failed", reason: "unavailable" };
      }

      const endpoint = requireOAuthEndpoint(material.tokenUrl.trim(), "Token endpoint");
      const fields: Record<string, string> = {
        grant_type: "refresh_token",
        refresh_token: material.refreshToken,
        client_id: material.clientId,
        ...(material.clientSecret !== null ? { client_secret: material.clientSecret } : {}),
        ...(material.resource !== null && material.resource !== "" ? { resource: material.resource } : {}),
      };
      const { response, signal, cleanup } = await fetchWithHeaderDeadline(deps.fetchImpl, endpoint.toString(), {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
        body: new URLSearchParams(fields).toString(),
        redirect: "manual",
      }, input.signal);
      try {
        const egress = egressResponseFromDecodedFetch(response, endpoint);
        const limits = {
          ...DEFAULT_EGRESS_LIMITS,
          totalMs: 30_000,
          responseBytes: 16_384,
          decompressedBytes: 65_536,
        };
        await assertBoundedHeadersOrCancel(egress, limits);
        const bytes = await readOAuthBody(egress, limits, signal);
        let body: Record<string, unknown> | null = null;
        try {
          const parsed: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
          if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
            body = parsed as Record<string, unknown>;
          }
        } catch {
          // Status mapping below stays bounded even for malformed provider text.
        }

        if (body?.error === "invalid_grant") return { status: "failed", reason: "invalid_grant" };
        if (response.status === 400 || response.status === 401 || response.status === 403) {
          return { status: "failed", reason: "unauthorized" };
        }
        if (response.status < 200 || response.status >= 300 || body === null) {
          return { status: "failed", reason: "unavailable" };
        }
        const parsed = parsedAccessToken(body, now());
        if (parsed === null || input.signal.aborted) return { status: "failed", reason: "unavailable" };

        const merged: SealedTokenMaterial = {
          ...material,
          accessToken: parsed.accessToken,
          refreshToken: parsed.refreshToken ?? material.refreshToken,
          expiresAt: parsed.expiresAt,
        };
        const sealed = deps.crypto.encrypt(
          JSON.stringify(merged),
          `mcp_oauth_tokens:${identity.connectionId}`,
        );
        const stored = signal.aborted ? false : await input.writeToken(sealed);
        // The shared outcome is status-only. merged/sealed leave this stack when
        // the originating call settles and never enter the single-flight map.
        return stored && !signal.aborted
          ? { status: "refreshed" }
          : { status: "failed", reason: "unavailable" };
      } finally {
        cleanup();
      }
    } catch {
      return { status: "failed", reason: "unavailable" };
    }
  };
}
