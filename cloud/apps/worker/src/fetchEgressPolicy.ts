import {
  createGuardedEgressFetch,
  SsrfBlockedError,
  type EgressFetch,
  type SsrfGuard,
} from "@ovid/agent-core";

/**
 * Original-fetch egress with the native handler's per-hop downgrade policy.
 *
 * createGuardedEgressFetch still owns scheme/port/DNS validation, manual
 * redirect following, the redirect limit, RequestInit forwarding, and response
 * cleanup. The per-request guard adds only the missing HTTPS -> non-HTTPS
 * refusal, before the downgrade target is resolved or fetched. Direct HTTP
 * requests retain the existing public-fetch behavior.
 */
export function createFetchEgressPolicy(
  guard: SsrfGuard,
  fetchImpl: typeof fetch = fetch,
): EgressFetch {
  return async (url: string, init?: RequestInit): Promise<Response> => {
    // Redirect history is request-local: concurrent fetches must never compare
    // their current hop with another request's previous hop.
    let previous: URL | undefined;
    const redirectGuard: SsrfGuard = {
      checkHost: (host) => guard.checkHost(host),
      assertSafeUrl: async (rawUrl: string): Promise<URL> => {
        let candidate: URL | null = null;
        try {
          candidate = new URL(rawUrl);
        } catch {
          // The wrapped guard owns the established invalid-URL failure.
        }
        if (
          previous?.protocol === "https:" &&
          candidate !== null &&
          candidate.protocol !== "https:"
        ) {
          throw new SsrfBlockedError("egress_redirect_downgrade");
        }
        const next = await guard.assertSafeUrl(rawUrl);
        previous = next;
        return next;
      },
    };
    return createGuardedEgressFetch(redirectGuard, fetchImpl)(url, init);
  };
}
