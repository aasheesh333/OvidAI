import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Redis } from "ioredis";
import { HttpContractError, type MintDeps } from "../app.js";
import { isBanned } from "../antiAbuse.js";
import { requireInternalSignature } from "../internalAuth.js";
import { requireNoDeletionFence } from "../mintRoutes.js";
import { effectiveTier, freeCapRemaining } from "../windows.js";
import type { Admission } from "./admission.js";
import type { LiteLlmImageService } from "./service.js";
import { IMAGE_ALIAS, ImageError } from "./types.js";

/**
 * Signed server-to-server image routes on mint's ADMIN listener.
 *
 * The worker's `generate_image` / `edit_image` tools execute HOST-SIDE (never
 * inside the sandbox), so provider credentials never reach the agent. They
 * call this surface instead of the public `/v1/images/*` routes because the
 * public routes require a Firebase ID token + App Check token, which a
 * background worker does not have. The HMAC contract is the same one
 * `/internal/mint-key` already uses (see cloud/docs/internal-mint-auth.md):
 *
 *   POST /internal/v1/images/capabilities
 *   POST /internal/v1/images/generations
 *   POST /internal/v1/images/edits
 *
 * Every route is POST so the uid rides the signed body. The service and the
 * admission bridge are the SAME instances the public routes use: quota,
 * ledger, receipts, capability routing and plan limits are not reimplemented
 * here. The public listener never registers these paths (pinned by the 404
 * test on publicApp).
 */

export const INTERNAL_IMAGE_CAPABILITIES_PATH = "/internal/v1/images/capabilities";
export const INTERNAL_IMAGE_GENERATIONS_PATH = "/internal/v1/images/generations";
export const INTERNAL_IMAGE_EDITS_PATH = "/internal/v1/images/edits";

const REQUEST_ID_RE = /^[A-Za-z0-9_.:-]{8,128}$/;

const SERVICE_BODY_KEYS = [
  "model",
  "prompt",
  "size",
  "requirements",
  "preference",
  "image",
  "mask",
  "images",
] as const;

function bodyOf(request: FastifyRequest): Record<string, unknown> {
  return typeof request.body === "object" && request.body !== null && !Array.isArray(request.body)
    ? (request.body as Record<string, unknown>)
    : {};
}

function uidOf(body: Record<string, unknown>): string {
  return typeof body.uid === "string" ? body.uid.trim() : "";
}

function nowSeconds(deps: MintDeps): number {
  return Math.floor((deps.clock?.() ?? new Date()).getTime() / 1000);
}

function sendImageError(reply: FastifyReply, error: ImageError): FastifyReply {
  const body: { error: Record<string, unknown>; receipt?: unknown } = {
    error: { code: error.code },
  };
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  if (error.retryAfterSeconds !== null) {
    body.error.retryAfterSeconds = error.retryAfterSeconds;
    headers["Retry-After"] = String(error.retryAfterSeconds);
  }
  if (error.detail !== null) Object.assign(body.error, error.detail);
  if (error.receipt !== null) body.receipt = error.receipt;
  return reply.code(error.status).headers(headers).send(body);
}

/** Android key first, then web — the same namespace order as the mint pool. */
async function firstUserKey(
  redis: Redis,
  uid: string,
  suffix: "key" | "keyid",
): Promise<string | null> {
  for (const ns of ["", "web:"] as const) {
    const value = await redis.get(`user:${uid}:${ns}${suffix}`);
    if (value !== null && value !== "") return value;
  }
  return null;
}

/**
 * Re-check the virtual key before any paid work. The public VerifierAuth
 * already enforces the `ovid-image` scope; the internal caller is trusted to
 * name the right uid, but a key that cannot serve the alias would fail
 * upstream ambiguously (and reserve budget), so it is refused here.
 */
async function imageKeyId(deps: MintDeps, uid: string): Promise<string> {
  const key = await firstUserKey(deps.redis, uid, "key");
  const keyId = await firstUserKey(deps.redis, uid, "keyid");
  if (key === null || keyId === null) {
    throw new ImageError(401, "sign_in_required");
  }
  const { status, info } = await deps.litellm.keyInfoStatus(keyId);
  if (status !== 200 || info === null) {
    throw new ImageError(401, "sign_in_required");
  }
  if (
    info.blocked ||
    !(info.models ?? []).includes(IMAGE_ALIAS) ||
    info.user_id !== uid ||
    (info.metadata ?? {}).ovid_uid !== uid
  ) {
    throw new ImageError(403, "image_access_denied");
  }
  return keyId;
}

export interface InternalImagesRouteOptions {
  /** Test seams; production uses the same windows/anti-abuse ladder as public. */
  effectiveTier?(deps: MintDeps, uid: string): Promise<string>;
  freeCapRemaining?(deps: MintDeps, uid: string): Promise<number>;
  deletionPending?(deps: MintDeps, uid: string): Promise<boolean>;
}

async function requireSigned(
  deps: MintDeps,
  request: FastifyRequest,
  path: string,
  uid: string,
  opts: InternalImagesRouteOptions,
): Promise<void> {
  requireInternalSignature(deps, request, path, uid, nowSeconds(deps));
  if (uid === "") throw new ImageError(401, "sign_in_required");
  if (await isBanned(deps, uid, "")) throw new ImageError(403, "image_access_denied");
  if (opts.deletionPending !== undefined) {
    if (await opts.deletionPending(deps, uid)) {
      throw new ImageError(403, "account_deletion_pending");
    }
  } else {
    // requireNoDeletionFence speaks the legacy {"detail"} envelope; the image
    // surface keeps its own {"error":{"code"}} envelope for every failure.
    try {
      await requireNoDeletionFence(deps, uid);
    } catch (err) {
      if (err instanceof HttpContractError) {
        throw new ImageError(err.status, "account_deletion_pending");
      }
      throw err;
    }
  }
}

function serviceBody(body: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const key of SERVICE_BODY_KEYS) {
    if (body[key] !== undefined) out[key] = body[key];
  }
  return out;
}

export function registerInternalImagesRoutes(
  adminApp: FastifyInstance,
  deps: MintDeps,
  service: LiteLlmImageService | null,
  admission: Admission | null,
  opts: InternalImagesRouteOptions = {},
): void {
  const tierOf = (uid: string) =>
    (opts.effectiveTier ?? effectiveTier)(deps, uid);
  const freeRemaining = (uid: string) =>
    (opts.freeCapRemaining ?? freeCapRemaining)(deps, uid);
  const requireMount = (): void => {
    if (service === null || admission === null) {
      throw new ImageError(503, "image_unavailable");
    }
  };

  adminApp.post(INTERNAL_IMAGE_CAPABILITIES_PATH, async (request, reply) => {
    try {
      requireMount();
      const body = bodyOf(request);
      const uid = uidOf(body);
      await requireSigned(deps, request, INTERNAL_IMAGE_CAPABILITIES_PATH, uid, opts);
      const tier = await tierOf(uid);
      const catalog = (await service!.catalog()) as unknown as Record<string, unknown>;
      return reply.headers({ "Cache-Control": "no-store" }).send({
        ...catalog,
        // Truthful plan state for the worker's capability cards. Models are
        // global; the allowance is per user and is re-checked at admission.
        quota: {
          tier,
          free_cap_remaining: tier === "free" ? await freeRemaining(uid) : null,
        },
      });
    } catch (error) {
      if (error instanceof ImageError) return sendImageError(reply, error);
      throw error;
    }
  });

  const execute = (operation: "generate" | "edit", path: string) =>
    async (request: FastifyRequest, reply: FastifyReply) => {
      try {
        requireMount();
        const body = bodyOf(request);
        const uid = uidOf(body);
        await requireSigned(deps, request, path, uid, opts);
        const requestId = typeof body.request_id === "string" ? body.request_id : "";
        if (!REQUEST_ID_RE.test(requestId)) {
          throw new ImageError(400, "invalid_request_id");
        }
        const keyId = await imageKeyId(deps, uid);
        const identity = { uid, keyId, tier: await tierOf(uid) };
        const result = await admission!(identity, (ctx) =>
          service!.execute(
            uid,
            requestId,
            operation,
            serviceBody(body),
            ctx.budget,
            { budgetWindow: ctx.window },
          ),
        );
        return reply.headers({ "Cache-Control": "no-store" }).send(result);
      } catch (error) {
        if (error instanceof ImageError) return sendImageError(reply, error);
        throw error;
      }
    };

  adminApp.post(INTERNAL_IMAGE_GENERATIONS_PATH, execute("generate", INTERNAL_IMAGE_GENERATIONS_PATH));
  adminApp.post(INTERNAL_IMAGE_EDITS_PATH, execute("edit", INTERNAL_IMAGE_EDITS_PATH));
}
