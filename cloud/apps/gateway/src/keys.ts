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
 * Thrown by createHttpMintProvisioner when the mint call exceeds its deadline.
 * The messages route maps it to a bounded 503 `unavailable` (never a hung
 * request, never a misleading key_not_minted).
 */
export class MintTimeoutError extends Error {
  readonly timeoutMs: number;

  constructor(timeoutMs: number, options?: { cause?: unknown }) {
    super(`mint call exceeded its ${timeoutMs} ms deadline`, options);
    this.name = "MintTimeoutError";
    this.timeoutMs = timeoutMs;
  }
}

/** P10 Task 2: default deadline for the gateway's internal-mint HTTP call. */
export const DEFAULT_MINT_TIMEOUT_MS = 10_000;

function isTimeoutError(err: unknown): boolean {
  return (
    err instanceof MintTimeoutError ||
    (typeof err === "object" &&
      err !== null &&
      (err as { name?: unknown }).name === "TimeoutError")
  );
}

/**
 * POSTs `{mintBaseUrl}/mint`, forwarding the caller's Authorization and
 * X-Firebase-AppCheck headers verbatim with an empty JSON body. Non-2xx
 * responses throw MintHttpError with status + body preserved (402/429
 * passthrough is the route's decision, made from those fields). Network
 * failures propagate as-is; a deadline breach surfaces as MintTimeoutError.
 */
export function createHttpMintProvisioner(
  mintBaseUrl: string,
  fetchImpl: typeof fetch = fetch,
  timeoutMs: number = DEFAULT_MINT_TIMEOUT_MS,
): MintProvisioner {
  const base = mintBaseUrl.replace(/\/+$/, "");
  return {
    async ensureKey(idToken, appCheck) {
      // Fresh per call: AbortSignal.timeout is single-use and starts ticking
      // at creation.
      const deadline =
        Number.isFinite(timeoutMs) && timeoutMs > 0
          ? AbortSignal.timeout(timeoutMs)
          : undefined;
      const headers: Record<string, string> = {
        authorization: `Bearer ${idToken}`,
        "content-type": "application/json",
      };
      if (appCheck !== null) {
        headers["x-firebase-appcheck"] = appCheck;
      }
      let res: Response;
      try {
        res = await fetchImpl(`${base}/mint`, {
          method: "POST",
          headers,
          body: "{}",
          ...(deadline !== undefined ? { signal: deadline } : {}),
        });
      } catch (err) {
        if (isTimeoutError(err) || (deadline?.aborted ?? false)) {
          throw new MintTimeoutError(timeoutMs, { cause: err });
        }
        throw err;
      }
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
