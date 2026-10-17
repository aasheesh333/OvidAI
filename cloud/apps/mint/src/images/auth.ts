import { timingSafeEqual } from "node:crypto";
import type { Redis } from "ioredis";
import type { MintIdentityVerifier } from "../app.js";
import type { MintEnv } from "../env.js";
import type { LiteLlmAdmin } from "../litellmAdmin.js";
import { IMAGE_ALIAS, ImageError } from "./types.js";

/**
 * Port of server/images/verifier.py VerifierAuth.
 *
 * The images surface never grows a second account/key store: it reuses the
 * mint verifier (Firebase ID token + App Check), the per-UID virtual key in
 * Redis db2, and LiteLLM `/key/info`. Explicit `ovid-image` scope is
 * mandatory — an unrestricted legacy key does not silently gain paid image
 * access. Receipt reads use verifyIdentity(), which skips only the free-quota
 * gate (a user who spent the cap can still retrieve what they already paid
 * for); everything else is rechecked.
 */

export interface ImagesIdentity {
  uid: string;
  keyId: string;
  tier: string;
}

export interface ImagesAuth {
  authenticate(headers: Record<string, string>): Promise<ImagesIdentity>;
  verifyIdentity(headers: Record<string, string>): Promise<ImagesIdentity>;
}

export interface ImagesAuthDeps {
  env: MintEnv;
  redis: Redis;
  litellm: LiteLlmAdmin;
  verifyIdentity: MintIdentityVerifier;
  effectiveTier(uid: string): Promise<string>;
  freeCapRemaining(uid: string): Promise<number>;
  isBanned(uid: string, ip: string): Promise<boolean>;
  clock?: () => number;
}

function lowerHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers)) {
    out[key.toLowerCase()] = value;
  }
  return out;
}

function header(headers: Record<string, string>, name: string): string {
  return headers[name.toLowerCase()] ?? "";
}

/** Constant-time comparison; the length guard keeps timingSafeEqual safe. */
function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left, "utf8");
  const b = Buffer.from(right, "utf8");
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * Python datetime.fromisoformat(...): naive timestamps are UTC. Date.parse
 * accepts the same ISO-8601 shapes once a trailing Z is supplied.
 */
function expiryMillis(raw: unknown): number | null {
  if (typeof raw !== "string" || raw.trim() === "") return null;
  let text = raw.trim();
  if (!/(?:[zZ]|[+-]\d{2}:?\d{2})$/.test(text)) text = `${text}Z`;
  const millis = Date.parse(text);
  return Number.isFinite(millis) ? millis : null;
}

class VerifierAuth implements ImagesAuth {
  constructor(private readonly deps: ImagesAuthDeps) {}

  async verifyIdentity(headers: Record<string, string>): Promise<ImagesIdentity> {
    const values = lowerHeaders(headers);
    const authorization = header(values, "authorization");
    if (!/^bearer /i.test(authorization)) {
      throw new ImageError(401, "sign_in_required");
    }
    const appcheck = header(values, "x-firebase-appcheck");
    if (this.deps.env.appcheckEnabled && appcheck === "") {
      throw new ImageError(401, "sign_in_required");
    }

    const identity = await this.deps.verifyIdentity({
      authorization,
      appcheck,
      xff: header(values, "x-forwarded-for"),
      xRealIp: header(values, "x-real-ip"),
    });
    const uid = identity.uid;

    if (await this.deps.isBanned(uid, "unknown")) {
      throw new ImageError(403, "image_access_denied");
    }

    const key = header(values, "x-ovid-key");
    const current = await this.deps.redis.get(`user:${uid}:key`);
    const keyId = await this.deps.redis.get(`user:${uid}:keyid`);
    if (key === "" || !current || !keyId || !safeEqual(key, current)) {
      throw new ImageError(401, "sign_in_required");
    }

    const { status, info } = await this.deps.litellm.keyInfoStatus(keyId);
    if (status !== 200 || info === null) {
      throw new ImageError(401, "sign_in_required");
    }
    // Explicit alias scope is mandatory.
    if (info.blocked === true || !(info.models ?? []).includes(IMAGE_ALIAS)) {
      throw new ImageError(403, "image_access_denied");
    }
    if (info.user_id !== uid || (info.metadata ?? {}).ovid_uid !== uid) {
      throw new ImageError(403, "image_access_denied");
    }
    if (info.expires !== undefined && info.expires !== null && info.expires !== "") {
      const expiry = expiryMillis(info.expires);
      const now = (this.deps.clock ?? (() => Date.now()))();
      if (expiry === null || expiry <= now) {
        throw new ImageError(401, "sign_in_required");
      }
    }

    return { uid, keyId, tier: await this.deps.effectiveTier(uid) };
  }

  async authenticate(headers: Record<string, string>): Promise<ImagesIdentity> {
    const identity = await this.verifyIdentity(headers);
    if (identity.tier === "free" && (await this.deps.freeCapRemaining(identity.uid)) <= 0) {
      throw new ImageError(402, "image_limit_reached");
    }
    return identity;
  }
}

export function createImagesAuth(deps: ImagesAuthDeps): ImagesAuth {
  return new VerifierAuth(deps);
}
