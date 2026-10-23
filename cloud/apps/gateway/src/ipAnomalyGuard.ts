/**
 * Request-admission glue between the observation store and the pure decision
 * function.
 *
 * One call does the whole per-send job: resolve the client IP from a trusted
 * hop, append the observation, and evaluate the resulting window. The route
 * consumes only `{ block, reason }`.
 *
 * FAIL-OPEN ON STORE FAILURE. If Redis is unavailable, admission returns
 * `{ block: false, reason: "store_unavailable" }` and reports the error. A
 * cache outage must not turn every send into a 403; mint's own per-key quota
 * and rate limiting remain the backstop. This is a deliberate availability
 * choice, and `store_unavailable` keeps it visible in logs/metrics rather
 * than disguising it as normal traffic.
 */

import {
  DEFAULT_IP_ANOMALY_POLICY,
  evaluateIpAnomaly,
  type IpAnomalyPolicy,
  type IpAnomalyReason,
} from "./anomaly.js";
import {
  DEFAULT_TRUSTED_PROXY_CIDRS,
  compileTrustedProxies,
  resolveClientIp,
} from "./clientIp.js";
import type { IpObservationStore } from "./ipObservations.js";

/** `store_unavailable` is admission-specific; the rest come from anomaly.ts. */
export type IpAdmissionReason = IpAnomalyReason | "store_unavailable";

export interface IpAdmissionDecision {
  block: boolean;
  reason: IpAdmissionReason;
}

export interface IpAnomalyRequestContext {
  /** request.socket.remoteAddress — never request.ip (trustProxy is off). */
  peerAddress: string | undefined;
  /** request.headers["x-forwarded-for"]. */
  forwardedFor: string | readonly string[] | undefined;
}

export interface IpAnomalyGuard {
  admit(uid: string, request: IpAnomalyRequestContext): Promise<IpAdmissionDecision>;
}

export interface IpAnomalyGuardOptions {
  store: IpObservationStore;
  /** OVID_TRUSTED_PROXY_CIDRS; defaults to the documented reverse-proxy set. */
  trustedProxyCidrs?: readonly string[];
  policy?: IpAnomalyPolicy;
  /** Epoch-ms clock (tests pin it). */
  now?: () => number;
  /** Error sink for a degraded store (defaults to silence; main logs it). */
  onError?: (err: unknown) => void;
}

export function createIpAnomalyGuard(
  opts: IpAnomalyGuardOptions,
): IpAnomalyGuard {
  const trustedProxies = compileTrustedProxies(
    opts.trustedProxyCidrs ?? DEFAULT_TRUSTED_PROXY_CIDRS,
  );
  const policy = opts.policy ?? DEFAULT_IP_ANOMALY_POLICY;
  const now = opts.now ?? (() => Date.now());

  return {
    async admit(uid, request) {
      const at = now();
      const clientIp =
        resolveClientIp({
          peerAddress: request.peerAddress,
          forwardedFor: request.forwardedFor,
          trustedProxies,
        }) ?? "";

      // ASN is not supplied by today's edge (Caddy forwards XFF only), so
      // this is always null and the decision uses the network fallback.
      // An ASN-aware edge can populate it without changing this flow.
      const observation = { ip: clientIp, asn: null, at };

      try {
        const observations = await opts.store.record(uid, observation);
        return evaluateIpAnomaly(observations, at, policy);
      } catch (err) {
        opts.onError?.(err);
        return { block: false, reason: "store_unavailable" };
      }
    },
  };
}
