import type { Redis } from "ioredis";
import {
  AUTO_ALIASES,
  createSsrfGuard,
  type ResolvedKey as AgentResolvedKey,
  type SsrfGuard,
} from "@ovid/agent-core";
import {
  INTERNAL_MINT_PATH,
  signInternalRequest,
  type ByokKeyProvider,
  type KeyResolver,
  type ResolvedKey,
} from "@ovid/shared";

/**
 * P9 Task 9 — the worker's server-side key resolver.
 *
 * Resolution order (pinned):
 *   1. `ctx.byokKeyId` → the escrow provider's decrypted record. A referenced
 *      BYOK key that cannot be decrypted FAILS the run (null). Silent
 *      fallback to Ovid's LiteLLM key would bill Ovid for the user's BYOK
 *      run — a billing defect, not a convenience.
 *   2. `GET user:{uid}:key` from mint's db2 projection.
 *   3. A Redis miss on an UNATTENDED run → signed POST /internal/mint-key
 *      (HMAC; see @ovid/shared internalAuth.ts).
 *   4. A Redis miss on an ATTENDED run → null. P4's `key_not_minted`
 *      contract is unchanged: the client can mint through the gateway.
 *   5. Internal 401/402/403 → null with the reason logged. Those are policy
 *      answers, never infrastructure errors; other non-2xx/network failures
 *      throw so BullMQ retries the job.
 *
 * USE-TIME SSRF (T11 review carry): POST /byok's endpoint validation is not
 * trusted at run time. Every decrypted endpoint is re-checked through
 * `SsrfGuard.assertSafeUrl` (the same `isNonPublicAddress` classifier the
 * egress uses). The endpoint is NEVER added to the trusted provider-origin
 * allowlist — `createProviderEgress` sends every non-allowlisted origin
 * through the full guarded fetch.
 *
 * Logging carries `{id, uid}` only: never the key, the endpoint or the
 * envelope.
 */

export interface KeyResolverDeps {
  redisMint: Redis;
  internalMint: { baseUrl: string; secret: string };
  byok: ByokKeyProvider | null;
  litellmBaseUrl: string;
  fetchImpl?: typeof fetch;
  /** Test seam; production uses createSsrfGuard(). */
  guard?: Pick<SsrfGuard, "assertSafeUrl">;
  /** Diagnostics sink; defaults to console.warn. */
  log?: (message: string, detail?: unknown) => void;
}

/** P9 internal-mint deadline (ms). A breach is an infra failure → job retry. */
export const INTERNAL_MINT_TIMEOUT_MS = 10_000;

function parseBody(text: string): unknown {
  if (text === "") return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export function createServerKeyResolver(deps: KeyResolverDeps): KeyResolver {
  const log =
    deps.log ??
    ((message: string, detail?: unknown) => {
      console.warn(`[worker] ${message}`, detail ?? "");
    });
  const guard = deps.guard ?? createSsrfGuard();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const base = deps.internalMint.baseUrl.replace(/\/+$/, "");

  async function mintInternal(uid: string): Promise<ResolvedKey | null> {
    const timestamp = Math.floor(Date.now() / 1000);
    let res: Response;
    try {
      res = await fetchImpl(`${base}${INTERNAL_MINT_PATH}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Ovid-Timestamp": Buffer.from(String(timestamp), "utf8").toString("base64"),
          "X-Ovid-Signature": signInternalRequest(
            deps.internalMint.secret,
            "POST",
            INTERNAL_MINT_PATH,
            uid,
            timestamp,
          ),
        },
        body: JSON.stringify({ uid }),
        signal: AbortSignal.timeout(INTERNAL_MINT_TIMEOUT_MS),
      });
    } catch (err) {
      // Network/timeout: an infrastructure failure. Throw so the job retries
      // rather than telling the client the account has no key.
      throw new Error(
        `internal mint call failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    const body = parseBody(await res.text());
    if (!res.ok) {
      if (res.status === 401 || res.status === 402 || res.status === 403) {
        log("internal mint refused the request", { uid, status: res.status });
        return null;
      }
      throw new Error(`internal mint responded with HTTP ${res.status}`);
    }
    const key = (body as { key?: unknown } | null)?.key;
    if (typeof key !== "string" || key === "") {
      throw new Error("internal mint returned a malformed 2xx body (no string key)");
    }
    return { kind: "litellm", key, baseUrl: deps.litellmBaseUrl };
  }

  return {
    async resolveForRun(uid, ctx) {
      // 1. Explicit BYOK reference — authoritative when present.
      if (ctx.byokKeyId !== undefined && ctx.byokKeyId !== null) {
        const byokKeyId = ctx.byokKeyId;
        if (deps.byok === null) {
          log("byok key referenced but escrow is not configured; failing the run", {
            id: byokKeyId,
            uid,
          });
          return null;
        }
        const record = await deps.byok.getDecrypted(byokKeyId, uid);
        if (record === null) {
          log("byok key unavailable; failing the run", { id: byokKeyId, uid });
          return null;
        }
        const endpoint = record.endpoint;
        try {
          // Validate only — never rewrite the canonical escrow endpoint
          // (URL.toString() would add a trailing slash).
          await guard.assertSafeUrl(record.endpoint);
        } catch {
          log("byok endpoint rejected at use time", { id: byokKeyId, uid });
          return null;
        }
        return {
          kind: "byok",
          byokKeyId,
          providerId: record.providerId,
          endpoint,
          apiKey: record.apiKey,
        };
      }

      // 2. Mint's db2 projection.
      const stored = await deps.redisMint.get(`user:${uid}:key`);
      if (stored !== null && stored !== "") {
        return { kind: "litellm", key: stored, baseUrl: deps.litellmBaseUrl };
      }

      // 3/4. Unattended runs may mint server-to-server; attended runs keep
      // P4's key_not_minted contract.
      if (!ctx.unattended) return null;
      return mintInternal(uid);
    },
  };
}

// ---------------------------------------------------------------------------
// Mapping onto @ovid/agent-core's routing vocabulary
// ---------------------------------------------------------------------------

/**
 * Escrow stores an arbitrary `providerId`; the agent-core transports know
 * two wire dialects. Anthropic-family ids ride the anthropic transport;
 * `openai` and every other id ride the openai-compatible transport.
 * (Providers requiring bespoke auth schemes — e.g. Azure `api-key` — are not
 * representable by P3's transports yet; they are still sent through the
 * openai-compatible transport, which is the closest correct shape.)
 */
export function byokProviderKind(providerId: string): "anthropic" | "openai" {
  const normalized = providerId.toLowerCase().replace(/[^a-z0-9]/g, "");
  return normalized === "claude" || normalized.includes("anthropic")
    ? "anthropic"
    : "openai";
}

/**
 * Maps a shared `ResolvedKey` onto the agent-core resolver's output.
 * `requestedModel` empty or an AUTO alias resolves to the fleet default
 * (the same rule as `litellmKeyResolver`).
 *
 * The BYOK endpoint is stamped as the route baseUrl; it is NOT trusted by
 * the egress — `createProviderEgress` only bypasses the SSRF guard for the
 * operator-configured LiteLLM/anthropic origins, so a BYOK URL always takes
 * the fully guarded path.
 */
export function agentKeyFor(
  key: ResolvedKey,
  requestedModel: string,
  defaultModel: string,
): AgentResolvedKey {
  const requested = requestedModel.trim();
  const model =
    requested === "" || (AUTO_ALIASES as readonly string[]).includes(requested)
      ? defaultModel
      : requested;

  if (key.kind === "litellm") {
    return { kind: "litellm", apiKey: key.key, baseUrl: key.baseUrl, model };
  }
  if (byokProviderKind(key.providerId) === "anthropic") {
    return { kind: "byok-anthropic", apiKey: key.apiKey, baseUrl: key.endpoint, model };
  }
  // openai-compatible: the litellm kind selects the openai transport in
  // routing.ts; the baseUrl is the BYOK endpoint, never the LiteLLM origin.
  return { kind: "litellm", apiKey: key.apiKey, baseUrl: key.endpoint, model };
}
