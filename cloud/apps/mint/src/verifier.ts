import { applicationDefault, getApps, initializeApp, type App } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getAuth } from "firebase-admin/auth";
import { users as usersRepo, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { HttpContractError, type MintIdentityVerifier } from "./app.js";
import type { MintEnv } from "./env.js";

/**
 * Task 6 verifier — firebase-admin replaces mint.py's raw-JWKS checks with the
 * same allowlist env semantics:
 *   - Firebase ID token (RS256, audience/issuer checked by the SDK);
 *   - Firebase App Check token (Play Integrity on Android, reCAPTCHA
 *     Enterprise on web), mapped to a platform through OVID_APPCHECK_APPS
 *     ("android:<appId>,web:<appId>"), else the ":web:" app-id heuristic.
 *
 * mint.py's firing order is preserved: bearer → App Check presence → App Check
 * verification → ID token. When APPCHECK_ENABLED=false the platform is
 * "android" and the token is not inspected (mint.py's verify_app_check).
 *
 * firebase-admin is initialized LAZILY from GOOGLE_APPLICATION_CREDENTIALS so
 * importing this module never reaches the network. Tests inject the two
 * verify seams (no Firebase project needed).
 */

export interface MintVerifierOverrides {
  /** Returns the decoded claims: uid + optional email (firebase-admin shape). */
  verifyIdToken?: (token: string) => Promise<{ uid: string; email?: string | null }>;
  /** Returns the Firebase app id (firebase-admin's decoded.app_id). */
  verifyAppCheck?: (token: string) => Promise<{ appId: string }>;
}

let cachedApp: App | undefined;

function firebaseApp(env: MintEnv): App {
  if (cachedApp !== undefined) return cachedApp;
  const existing = getApps();
  cachedApp =
    existing.length > 0
      ? existing[0]!
      : initializeApp({
          credential: applicationDefault(),
          projectId: env.firebaseProjectId,
        });
  return cachedApp;
}

function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Index a verified Google email so the admin console can look users up by it
 * (mint.py remember_email). Postgres users.email is the durable authority
 * (Ruling Q4); Redis db2 carries the exact keys the hook/admin read:
 * user:{uid}:email + the reverse email:{email} → uid index. Never throws — a
 * failed index write must not fail sign-in.
 */
export async function rememberEmail(
  deps: { db: Db; redis: Redis },
  uid: string,
  email: string | null | undefined,
): Promise<void> {
  if (typeof email !== "string" || email.trim() === "") return;
  const normalized = email.trim().toLowerCase();
  try {
    // INSERT … ON CONFLICT: tier is untouched, a null email never clobbers.
    await usersRepo.ensure(deps.db, uid, normalized);
  } catch (err) {
    console.log(`[mint] email index (postgres) error: ${errorText(err)}`);
  }
  try {
    if ((await deps.redis.get(`user:${uid}:email`)) !== normalized) {
      await deps.redis.set(`user:${uid}:email`, normalized);
      await deps.redis.set(`email:${normalized}`, uid);
    }
  } catch (err) {
    console.log(`[mint] email index (redis) error: ${errorText(err)}`);
  }
}

/**
 * The canonical identity verifier. 401 messages are the legacy FastAPI
 * contract; an app id outside OVID_APPCHECK_APPS is 403 "unknown app".
 */
export function createMintVerifier(
  env: MintEnv,
  overrides: MintVerifierOverrides = {},
): MintIdentityVerifier {
  const verifyIdToken =
    overrides.verifyIdToken ??
    ((token: string) => getAuth(firebaseApp(env)).verifyIdToken(token));
  const verifyAppCheck =
    overrides.verifyAppCheck ??
    (async (token: string) => ({
      appId: (await getAppCheck(firebaseApp(env)).verifyToken(token)).appId,
    }));

  return async ({ authorization, appcheck }) => {
    if (!/^bearer /i.test(authorization)) {
      throw new HttpContractError(401, "missing bearer id token");
    }
    const idToken = authorization.slice(authorization.indexOf(" ") + 1);
    if (env.appcheckEnabled && appcheck === "") {
      throw new HttpContractError(401, "missing app check token");
    }

    let platform: "android" | "web" = "android";
    if (env.appcheckEnabled) {
      let appId: string;
      try {
        appId = String((await verifyAppCheck(appcheck)).appId ?? "");
      } catch (err) {
        throw new HttpContractError(401, `invalid app check token: ${errorText(err)}`);
      }
      const allowlist = Object.keys(env.appcheckApps);
      if (allowlist.length > 0) {
        const mapped = env.appcheckApps[appId];
        if (mapped === undefined) {
          throw new HttpContractError(403, "unknown app");
        }
        platform = mapped;
      } else {
        platform = appId.includes(":web:") ? "web" : "android";
      }
    }

    let claims: { uid: string; email?: string | null };
    try {
      claims = await verifyIdToken(idToken);
    } catch (err) {
      throw new HttpContractError(401, `invalid id token: ${errorText(err)}`);
    }
    if (claims.uid === undefined || claims.uid === null || claims.uid === "") {
      throw new HttpContractError(401, "no subject");
    }
    return {
      uid: claims.uid,
      email: claims.email ?? null,
      platform,
    };
  };
}
