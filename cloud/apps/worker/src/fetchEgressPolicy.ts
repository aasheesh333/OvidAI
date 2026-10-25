import {
  createGuardedEgressFetch,
  SsrfBlockedError,
  type EgressFetch,
  type SsrfGuard,
} from "@ovid/agent-core";
import {
  createPublicWebFetch,
  PUBLIC_WEB_FETCH_REQUEST,
  type PublicWebFetchRequestInit,
} from "@ovid/mcp";

/**
 * Select the checked-address public-web transport only for the native fetch
 * operation's non-wire marker. Other worker egress consumers (OAuth, plugin
 * resolution, and the credentialed GitHub REST port) retain the legacy guarded
 * policy and are not admitted into arbitrary public-web pinned transport.
 *
 * Native followGuardedRedirects owns redirect advancement/count. Each marked
 * call here handles only its current checked network hop and returns redirect
 * metadata to native; there is no nested redirect loop or direct-HTTP fallback.
 * The legacy branch remains compatibility behavior for those other callers,
 * and marked calls never fall back after DNS, TLS, policy, or transport failures.
 */
export function createFetchEgressPolicy(
  guard: SsrfGuard,
  fetchImpl: typeof fetch = fetch,
  publicWebFetchImpl: EgressFetch = createPublicWebFetch(),
): EgressFetch {
  return async (url: string, init?: RequestInit): Promise<Response> => {
    if ((init as PublicWebFetchRequestInit | undefined)?.[PUBLIC_WEB_FETCH_REQUEST] === true) {
      return publicWebFetchImpl(url, init);
    }

    // Redirect history is request-local: concurrent legacy fetches must never
    // compare their current hop with another request's previous hop.
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
