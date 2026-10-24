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
  resolveClientNetwork,
  type ClientNetwork,
} from "./clientIp.js";
import type { IpObservationStore } from "./ipObservations.js";
import { dataControlRepo, type Db } from "@ovid/db";
import type { KeyAdmin } from "@ovid/account";
import {
  type SuspensionMailer,
  type SuspensionMailOutcome,
} from "./suspensionMailer.js";

/** `store_unavailable` is admission-specific; the rest come from anomaly.ts. */
export type IpAdmissionReason = IpAnomalyReason | "store_unavailable";

export interface IpAdmissionDecision {
  block: boolean;
  reason: IpAdmissionReason;
  /** Present when durable automatic suspension is configured for this guard. */
  suspension?: "applied" | "degraded";
  /** Sanitized delivery result; absent means mail was not reached. */
  mailOutcome?: SuspensionMailOutcome;
}

export interface IpAnomalyRequestContext {
  /** request.socket.remoteAddress — never request.ip (trustProxy is off). */
  peerAddress: string | undefined;
  /** request.headers["x-forwarded-for"]. */
  forwardedFor: string | readonly string[] | undefined;
  /** Trusted-proxy ASN header; ignored for direct/malformed forwarding chains. */
  asn?: string | readonly string[] | undefined;
  /** Signed Cloudflare metadata verified by the rate-limit admission hook. */
  edge?: ClientNetwork;
}

export interface IpAnomalySuspensionInput {
  uid: string;
  blockId: string;
  reason: IpAnomalyReason;
}

export interface IpAnomalySuspension {
  suspend(input: IpAnomalySuspensionInput): Promise<{
    mailOutcome: SuspensionMailOutcome;
  }>;
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
  /** Durable account/key suspension. Rate limiting remains a separate concern. */
  suspension?: IpAnomalySuspension;
}

export interface IpAnomalySuspensionOptions {
  db: Db;
  /** Mint Redis: the live account-standing projection read before key use. */
  redis: { set(key: string, value: string): unknown };
  keyAdmin: Pick<KeyAdmin, "listKeys" | "keyBlock">;
  mailer: SuspensionMailer;
  now?: () => Date;
}

/**
 * Apply a REAL automatic block in security order: durable Postgres standing,
 * live Redis standing, every authority-listed LiteLLM key, then mail. Any
 * failure before mail throws (the guard still refuses the request); mail itself
 * is always an outcome and can never undo or weaken the block.
 */
export function createIpAnomalySuspension(
  opts: IpAnomalySuspensionOptions,
): IpAnomalySuspension {
  const now = opts.now ?? (() => new Date());
  return {
    async suspend({ uid, blockId }) {
      // The destination is read below from the server's own users row after
      // the security block, never accepted from the caller or request token.
      await opts.db.$client`
        INSERT INTO users (uid, banned_at, banned_reason)
        VALUES (${uid}, ${now().toISOString()}, 'auto')
        ON CONFLICT (uid) DO UPDATE
          SET banned_at = EXCLUDED.banned_at, banned_reason = 'auto'`;
      await opts.redis.set(`user:${uid}:banned`, "auto");

      const keyIds = [...new Set(await opts.keyAdmin.listKeys(uid))];
      for (const keyId of keyIds) {
        const status = await opts.keyAdmin.keyBlock(keyId);
        if (status < 200 || status >= 300) throw new Error("key block failed");
      }

      const registeredEmail = await dataControlRepo.registeredEmail(opts.db, uid);
      let mailOutcome: SuspensionMailOutcome;
      try {
        mailOutcome = await opts.mailer.send({ uid, blockId, registeredEmail });
      } catch {
        mailOutcome = "failed";
      }
      return { mailOutcome };
    },
  };
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
      const network = request.edge ?? resolveClientNetwork({
        peerAddress: request.peerAddress,
        forwardedFor: request.forwardedFor,
        asn: request.asn,
        trustedProxies,
      });
      const observation = { ip: network.ip ?? "", asn: network.asn, at };

      try {
        const observations = await opts.store.record(uid, observation);
        const decision = evaluateIpAnomaly(observations, at, policy);
        if (!decision.block || opts.suspension === undefined) return decision;
        const window = Math.floor(at / policy.windowMs);
        try {
          const outcome = await opts.suspension.suspend({
            uid,
            blockId: `anomaly:${uid}:${window}:${decision.reason}`,
            reason: decision.reason,
          });
          return { ...decision, suspension: "applied", mailOutcome: outcome.mailOutcome };
        } catch (err) {
          opts.onError?.(err);
          // The request remains blocked even if a later key-admin operation is
          // degraded. Never convert a security failure into an allow or mail sent.
          return { ...decision, suspension: "degraded" };
        }
      } catch (err) {
        opts.onError?.(err);
        return { block: false, reason: "store_unavailable" };
      }
    },
  };
}
