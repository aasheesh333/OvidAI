import type { Redis } from "ioredis";
import type { KeyProvider, MintProvisioner } from "@ovid/shared";

// Implementations of the @ovid/shared provisioning contracts (controller
// ruling: interfaces live in shared so the Task 9 worker imports them from
// there; implementations stay here in the gateway).

/**
 * Reads the user's provisioned key from the mint service's Redis:
 * `GET user:{uid}:key`. The REDIS_MINT_URL already carries the db selector
 * (mint's db2), so the given connection does a plain GET.
 */
export function createMintRedisKeyProvider(redisMint: Redis): KeyProvider {
  return {
    getKeyForUser(uid) {
      return redisMint.get(`user:${uid}:key`);
    },
  };
}

/**
 * Thrown by createHttpMintProvisioner on any non-2xx mint response, carrying
 * the status and the parsed body so the gateway can relay billing/rate-limit
 * envelopes (402/429) to the caller verbatim.
 */
export class MintHttpError extends Error {
  readonly status: number;
  readonly body: unknown;

  constructor(status: number, body: unknown) {
    super(`mint responded with HTTP ${status}`);
    this.name = "MintHttpError";
    this.status = status;
    this.body = body;
  }
}

/**
 * POSTs `{mintBaseUrl}/mint`, forwarding the caller's Authorization and
 * X-Firebase-AppCheck headers verbatim with an empty JSON body. Non-2xx
 * responses throw MintHttpError with status + body preserved (402/429
 * passthrough is the route's decision, made from those fields). Network
 * failures propagate as-is.
 */
export function createHttpMintProvisioner(
  mintBaseUrl: string,
  fetchImpl: typeof fetch = fetch,
): MintProvisioner {
  const base = mintBaseUrl.replace(/\/+$/, "");
  return {
    async ensureKey(idToken, appCheck) {
      const headers: Record<string, string> = {
        authorization: `Bearer ${idToken}`,
        "content-type": "application/json",
      };
      if (appCheck !== null) {
        headers["x-firebase-appcheck"] = appCheck;
      }
      const res = await fetchImpl(`${base}/mint`, {
        method: "POST",
        headers,
        body: "{}",
      });
      const text = await res.text();
      let body: unknown = text;
      if (text !== "") {
        try {
          body = JSON.parse(text);
        } catch {
          body = text; // non-JSON bodies are preserved as raw text
        }
      }
      if (!res.ok) {
        throw new MintHttpError(res.status, body);
      }
      const key = (body as { key?: unknown } | null)?.key;
      if (typeof key !== "string") {
        throw new Error("mint returned a malformed 2xx body (no string key)");
      }
      return { key };
    },
  };
}
