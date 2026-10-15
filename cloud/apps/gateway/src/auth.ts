import type { App } from "firebase-admin/app";
import {
  getAuth,
  type Auth,
  type DecodedIdToken,
} from "firebase-admin/auth";
import { getAppCheck, type AppCheck } from "firebase-admin/app-check";
import type { FastifyReply, preHandlerHookHandler } from "fastify";

export interface AuthPrincipal {
  uid: string;
  email: string | null;
  authTime: number;
}

export type Verifier = (
  idToken: string,
  appCheckToken: string | null,
) => Promise<AuthPrincipal>;

// Module augmentation so every FastifyRequest in the gateway (Task 7 routes,
// Task 8 WS handshake) sees `principal` as a typed, hook-assigned field.
declare module "fastify" {
  interface FastifyRequest {
    principal: AuthPrincipal;
  }
}

const BEARER_PREFIX = "Bearer ";
const APP_CHECK_HEADER = "x-firebase-appcheck";

// One generic envelope for every auth failure — missing header, bad scheme,
// verifier rejection — so failures are indistinguishable to the caller and
// firebase verification details never reach the response.
function unauthenticated(reply: FastifyReply): FastifyReply {
  return reply.code(401).send({
    error: { code: "unauthenticated", message: "Missing or invalid credentials." },
  });
}

// Internal marker for "this is a 401"; the hook maps every thrown error to
// the generic envelope regardless, so details stay server-side by design.
class UnauthenticatedError extends Error {}

/**
 * Production verifier: Firebase ID token + App Check on every handshake.
 *
 * The plan pins App Check on every request, so a MISSING App Check token is
 * rejected before the ID token is ever inspected. Both verifications run
 * against the caller-supplied app (initialized from ADC /
 * GOOGLE_APPLICATION_CREDENTIALS by the composition root, never here); the
 * firebase-admin services are constructed lazily on first use, which keeps
 * this module importable — and the missing-App-Check path testable — without
 * credentials.
 */
export function createFirebaseVerifier(app: App): Verifier {
  let services: { auth: Auth; appCheck: AppCheck } | null = null;
  return async (idToken, appCheckToken) => {
    if (appCheckToken === null) {
      throw new UnauthenticatedError("missing App Check token");
    }
    services ??= { auth: getAuth(app), appCheck: getAppCheck(app) };
    let decoded: DecodedIdToken;
    try {
      decoded = await services.auth.verifyIdToken(idToken);
      await services.appCheck.verifyToken(appCheckToken);
    } catch {
      // Swallow the verification error on purpose: alg/kid/expiry details are
      // an oracle we must not leak. The hook turns this into the generic 401.
      throw new UnauthenticatedError("token verification failed");
    }
    return {
      uid: decoded.uid,
      email: decoded.email ?? null,
      authTime: decoded.auth_time,
    };
  };
}

/**
 * Test-only verifier: accepts tokens of the exact form `test:<uid>` (uid
 * non-empty, no whitespace) and nothing else. Wiring code must never
 * construct this when authMode is "firebase" — and loadGatewayEnv refuses
 * authMode "test" entirely when NODE_ENV=production.
 */
export function createTestVerifier(): Verifier {
  return async (idToken, _appCheckToken) => {
    const match = /^test:(\S+)$/.exec(idToken);
    if (match === null) {
      throw new UnauthenticatedError("invalid test token");
    }
    return { uid: match[1], email: null, authTime: 0 };
  };
}

/** Header value → non-empty string or null (normalizes the string[] form). */
function headerValue(raw: string | string[] | undefined): string | null {
  const value = Array.isArray(raw) ? raw[0] : raw;
  return typeof value === "string" && value !== "" ? value : null;
}

/**
 * Fastify preHandler hook: reads `Authorization: Bearer <token>` plus
 * `X-Firebase-AppCheck`, runs the verifier, decorates `request.principal` on
 * success and answers every failure with the same 401
 * `{error:{code:"unauthenticated"}}` envelope.
 */
export function authHook(verifier: Verifier): preHandlerHookHandler {
  return async (request, reply) => {
    const authorization = headerValue(request.headers.authorization);
    const idToken =
      authorization !== null && authorization.startsWith(BEARER_PREFIX)
        ? authorization.slice(BEARER_PREFIX.length)
        : null;
    const appCheckToken = headerValue(request.headers[APP_CHECK_HEADER]);
    if (idToken === null || idToken === "") {
      // Task 6 review carry-over: every hook 401 is diagnosable server-side;
      // the client keeps the generic envelope.
      request.log.warn("auth rejected: missing or malformed Authorization header");
      return unauthenticated(reply);
    }
    try {
      request.principal = await verifier(idToken, appCheckToken);
    } catch (err) {
      // The verification error is still swallowed FOR THE CLIENT (alg/kid/
      // expiry details are an oracle we must not leak), but it is logged with
      // the request logger so outages are diagnosable server-side.
      request.log.warn({ err }, "auth verification failed");
      return unauthenticated(reply);
    }
    // Falls through to the route handler with request.principal set.
  };
}
