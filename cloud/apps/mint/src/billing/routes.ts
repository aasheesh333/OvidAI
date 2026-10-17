import type { FastifyInstance, FastifyReply } from "fastify";
import { HttpContractError, type MintDeps } from "../app.js";
import { isBanned } from "../antiAbuse.js";
import { requireNoDeletionFence } from "../mintRoutes.js";
import { BillingError } from "./domain.js";
import { pubsubPushVerifier } from "./pushAuth.js";
import type { BillingService } from "./service.js";

/**
 * POST /billing/verify and POST /billing/rtdn — port of server/billing/api.py.
 *
 * The verify route authenticates with mint's own Task-6 verifier (Firebase ID
 * token + App Check) and the same ban check as /mint; the RTDN route is
 * guarded by Pub/Sub push auth (OIDC preferred, shared-secret fallback,
 * fail-closed). Responses are never cached.
 */

/** In-scope JSON parser sentinel: malformed bodies are a contract value. */
const MALFORMED_BODY = Symbol("malformed-json-body");

function headerValue(value: string | string[] | undefined): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value[0] ?? "";
  return "";
}

function lowerHeaders(headers: Record<string, string | string[] | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers)) {
    out[key.toLowerCase()] = headerValue(value);
  }
  return out;
}

function sendBillingError(reply: FastifyReply, error: BillingError): FastifyReply {
  return reply
    .code(error.status)
    .header("Cache-Control", "no-store")
    .send({ ok: false, error: { code: error.code } });
}

function sendUnavailable(reply: FastifyReply): FastifyReply {
  return reply
    .code(503)
    .header("Cache-Control", "no-store")
    .send({ ok: false, error: { code: "billing_unavailable" } });
}

export interface BillingRouteOptions {
  /**
   * P9 final review H1: the account-deletion fence. Production uses the same
   * lightweight tombstone check as /mint, /upgrade and /internal/mint-key;
   * tests inject a deterministic seam.
   */
  deletionFence?(uid: string): Promise<void>;
}

export function registerBillingRoutes(
  publicApp: FastifyInstance,
  deps: MintDeps,
  billing: BillingService,
  opts: BillingRouteOptions = {},
): void {
  const deletionFence =
    opts.deletionFence ?? ((uid: string) => requireNoDeletionFence(deps, uid));
  // A SCOPED plugin so the tolerant JSON parser below cannot change the
  // legacy 400-on-malformed-JSON behavior of every other mint route.
  publicApp.register(async (scope) => {
    scope.addContentTypeParser(
      "application/json",
      { parseAs: "string" },
      (_request, body, done) => {
        try {
          done(null, JSON.parse(typeof body === "string" ? body : body.toString("utf8")));
        } catch {
          // Pub/Sub malformed pushes are acknowledged (204); verify maps it
          // to 400 invalid_request.
          done(null, MALFORMED_BODY);
        }
      },
    );

    scope.post("/billing/verify", async (request, reply) => {
      try {
        let uid: string;
        try {
          const identity = await deps.verifyIdentity({
            authorization: headerValue(request.headers.authorization),
            appcheck: headerValue(request.headers["x-firebase-appcheck"]),
            xff: headerValue(request.headers["x-forwarded-for"]),
            xRealIp: headerValue(request.headers["x-real-ip"]),
          });
          uid = identity.uid;
        } catch (err) {
          // Task-6's verifier already collapses to HttpContractError(401);
          // anything else is still an authentication failure here.
          if (err instanceof HttpContractError && err.status === 403) {
            return reply
              .code(403)
              .header("Cache-Control", "no-store")
              .send({ ok: false, error: { code: "account_blocked" } });
          }
          return reply
            .code(401)
            .header("Cache-Control", "no-store")
            .send({ ok: false, error: { code: "sign_in_required" } });
        }
        if (await isBanned(deps, uid, "unknown")) {
          return reply
            .code(403)
            .header("Cache-Control", "no-store")
            .send({ ok: false, error: { code: "account_blocked" } });
        }
        // P9 final review H1: a pending/fenced/deleting account must not bind
        // purchase tokens or change tiers during its 24 h grace window.
        await deletionFence(uid);

        const body = request.body === MALFORMED_BODY ? null : request.body;
        const result = await billing.verify(uid, body);
        return reply
          .code(result.status)
          .header("Cache-Control", "no-store")
          .send(result.payload);
      } catch (err) {
        if (err instanceof BillingError) {
          return sendBillingError(reply, err);
        }
        if (err instanceof HttpContractError) {
          // The deletion fence's 403 account_deletion_pending.
          return reply
            .code(err.status)
            .header("Cache-Control", "no-store")
            .send({ ok: false, error: { code: err.detail } });
        }
        // Never leak driver internals; the client sees the retryable code.
        request.log.error({ err }, "billing.verify failed");
        return sendUnavailable(reply);
      }
    });

    const verifyPush = pubsubPushVerifier(deps.env);

    scope.post("/billing/rtdn", async (request, reply) => {
      const headers = lowerHeaders(request.headers);
      const query: Record<string, string> = {};
      for (const [key, value] of Object.entries(
        (request.query ?? {}) as Record<string, unknown>,
      )) {
        query[key] = typeof value === "string" ? value : String(value ?? "");
      }
      if (!(await verifyPush(headers, query))) {
        return reply.code(403).send();
      }
      if (request.body === MALFORMED_BODY) {
        return reply.code(204).send();
      }
      try {
        await billing.notify(request.body);
      } catch (err) {
        if (err instanceof BillingError) {
          // Non-2xx makes Pub/Sub redeliver with backoff.
          return sendBillingError(reply, err);
        }
        request.log.error({ err }, "billing.rtdn failed");
        return reply.code(503).send();
      }
      return reply.code(204).send();
    });
  });
}
