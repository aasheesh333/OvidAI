import { timingSafeEqual } from "node:crypto";
import type { MintEnv } from "../env.js";

/**
 * Pub/Sub push authentication (port of api.pubsub_push_verifier).
 *
 * Preferred: OIDC push auth — `OVID_RTDN_AUDIENCE` + `OVID_RTDN_SERVICE_ACCOUNT`.
 * The bearer ID token must verify for that audience AND carry exactly that
 * service-account email with `email_verified === true`.
 * Fallback: `OVID_RTDN_SHARED_SECRET` passed as `?secret=`, compared
 * timing-safely. Neither configured → every push is refused (fail closed).
 */

export interface IdTokenVerifier {
  (token: string, audience: string): Promise<Record<string, unknown>>;
}

export interface PushAuthOverrides {
  /** Test seam: replaces google-auth-library's verifyIdToken. */
  verifyIdToken?: IdTokenVerifier;
}

export type PushVerifier = (
  headers: Record<string, string>,
  query: Record<string, string>,
) => Promise<boolean>;

function headerValue(headers: Record<string, string>, name: string): string {
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === name) {
      return typeof value === "string" ? value : "";
    }
  }
  return "";
}

function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  return left.length === right.length && timingSafeEqual(left, right);
}

async function googleVerifyIdToken(
  token: string,
  audience: string,
): Promise<Record<string, unknown>> {
  const { OAuth2Client } = await import("google-auth-library");
  const client = new OAuth2Client();
  const ticket = await client.verifyIdToken({ idToken: token, audience });
  return (ticket.getPayload() ?? {}) as Record<string, unknown>;
}

export function pubsubPushVerifier(env: MintEnv, overrides: PushAuthOverrides = {}): PushVerifier {
  const audience = env.play.rtdnAudience;
  const account = env.play.rtdnServiceAccount;
  const secret = env.play.rtdnSharedSecret;
  const verifyIdToken = overrides.verifyIdToken ?? googleVerifyIdToken;

  return async (headers, query) => {
    // OIDC is preferred; when configured it is the ONLY accepted scheme.
    if (audience !== null && account !== null) {
      const authorization = headerValue(headers, "authorization");
      if (!/^bearer /i.test(authorization)) {
        return false;
      }
      const token = authorization.slice(7).trim();
      if (token === "") {
        return false;
      }
      try {
        const claims = await verifyIdToken(token, audience);
        return claims.email === account && claims.email_verified === true;
      } catch {
        return false;
      }
    }
    if (secret !== null) {
      const provided = query.secret ?? "";
      return safeEqual(provided, secret);
    }
    return false;
  };
}
