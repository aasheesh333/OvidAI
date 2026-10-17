import type { FastifyInstance, FastifyRequest } from "fastify";
import { accountDeletions } from "@ovid/db";
import {
  clientIp,
  enforceIpSignupQuota,
  enforceMintRateLimit,
  isBanned,
} from "./antiAbuse.js";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { litellmMintOrGet } from "./keyMint.js";
import { findPlan, storedTier, windowStr } from "./planMath.js";
import { createProjection } from "./projection.js";
import { getSettings } from "./settings.js";
import { rememberEmail } from "./verifier.js";
import { effectiveTier, freeCapRemaining, planFor, reapplyUser } from "./windows.js";

/**
 * Public mint endpoints — the FastAPI surface the installed APK depends on:
 *
 *   POST /mint       one idempotent key per (uid, platform), tier + base_url
 *   POST /upgrade    ALLOW_TEST_UPGRADE-gated self tier change
 *   GET  /plans      enabled plans for the app's plan screen
 *   GET  /v1/models  sanitized passthrough of the user's LiteLLM catalog
 *
 * The /mint error ladder is pinned in mint.py's FIRING order (this is a hard
 * parity contract, asserted by mintRoutes.test.ts):
 *   verifier 401s → banned 403 → per-IP 429 → signup-velocity 429 →
 *   free-cap 402 (before key creation) → lock 409 (before the breaker) →
 *   new-key breaker 503 (inside the acquired lock).
 *
 * Anti-abuse rungs delegate to Task 7's antiAbuse.ts (clientIp / isBanned /
 * enforceMintRateLimit / enforceIpSignupQuota) — there is exactly one
 * implementation of those.
 */

function headerValue(v: string | string[] | undefined): string {
  if (typeof v === "string") return v;
  if (Array.isArray(v)) return v[0] ?? "";
  return "";
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}

/**
 * _catalog_error port. A rejected key must surface as 401 so the app
 * re-mints; LiteLLM reports an exhausted budget as 400/401/403/429 with
 * "budget" in the text → 402. Everything else stays 503.
 */
export function catalogError(
  status: number,
  text: string,
): { status: number; code: string } {
  if ([400, 401, 403, 429].includes(status) && text.toLowerCase().includes("budget")) {
    return { status: 402, code: "budget_exceeded" };
  }
  if (status === 401 || status === 403) {
    return { status: 401, code: "key_invalid" };
  }
  if (status === 429) {
    return { status: 429, code: "rate_limited" };
  }
  return { status: 503, code: "catalog_unavailable" };
}

/** The header pair clients use to tell a gateway outage from a rejected key. */
export const CATALOG_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store",
  "X-Ovid-Gateway": "2",
};

function identityHeaders(request: FastifyRequest): {
  authorization: string;
  appcheck: string;
  xff: string;
  xRealIp: string;
} {
  return {
    authorization: headerValue(request.headers.authorization),
    appcheck: headerValue(request.headers["x-firebase-appcheck"]),
    xff: headerValue(request.headers["x-forwarded-for"]),
    xRealIp: headerValue(request.headers["x-real-ip"]),
  };
}

/**
 * mint.py's route-level 401 checks, in the SAME order as /usage: bearer first,
 * then App Check presence (only while APPCHECK_ENABLED). The verifier repeats
 * them, but the route must answer before any side effect (remember_email) and
 * the parity tests assert these exact details.
 */
function requireIdentityHeaders(
  deps: MintDeps,
  headers: { authorization: string; appcheck: string },
): void {
  if (!/^bearer /i.test(headers.authorization)) {
    throw new HttpContractError(401, "missing bearer id token");
  }
  if (deps.env.appcheckEnabled && headers.appcheck === "") {
    throw new HttpContractError(401, "missing app check token");
  }
}

/**
 * P9 Task 15: the deletion tombstone check for the /mint hot path (the plan's
 * PIN: a lightweight `accountDeletions.get` here; the full lifecycle.access
 * lock is reserved for admin mutations and billing verify). A tombstone in
 * any state except cancelled/active fences new keys and tier upgrades.
 */
async function requireNoDeletionFence(deps: MintDeps, uid: string): Promise<void> {
  const row = await accountDeletions.get(deps.db, uid);
  if (row !== null && row.state !== "cancelled" && row.state !== "active") {
    throw new HttpContractError(403, "account_deletion_pending");
  }
}

export function registerMintRoutes(publicApp: FastifyInstance, deps: MintDeps): void {
  /**
   * POST /mint — identity, anti-abuse, free-cap, then the idempotent mint.
   * The tier returned is the STORED billing value (legacy 3x/7x/15x aliases).
   */
  publicApp.post("/mint", async (request, reply) => {
    const headers = identityHeaders(request);
    requireIdentityHeaders(deps, headers);
    const identity = await deps.verifyIdentity(headers);
    const uid = identity.uid;

    await rememberEmail(deps, uid, identity.email);

    const ip = clientIp(headers.xff, headers.xRealIp);
    if (await isBanned(deps, uid, ip)) {
      throw new HttpContractError(403, "account suspended");
    }
    await requireNoDeletionFence(deps, uid);
    await enforceMintRateLimit(deps, ip);
    await enforceIpSignupQuota(deps, uid, ip);

    const tier = await effectiveTier(deps, uid);
    // Free tier: stop at the monthly ceiling BEFORE any key work.
    if (tier === "free" && (await freeCapRemaining(deps, uid)) <= 0) {
      throw new HttpContractError(402, "monthly free limit reached");
    }

    const key = await litellmMintOrGet(
      deps,
      uid,
      tier,
      identity.platform,
      deps.mintLock,
    );
    const plan = await planFor(deps, uid);
    return reply.send({
      key,
      tier: storedTier(plan),
      base_url: deps.env.publicBaseUrl,
    });
  });

  /**
   * POST /upgrade — TEST-ONLY self tier change. The gate is checked FIRST
   * (before auth), exactly like mint.py. Disabled/unknown tiers resolve to
   * free. Postgres users.tier is written first, then the Redis projection is
   * published and the live keys are re-applied.
   */
  publicApp.post("/upgrade", async (request, reply) => {
    if (!deps.env.allowTestUpgrade) {
      throw new HttpContractError(403, "test upgrade is disabled");
    }
    const headers = identityHeaders(request);
    requireIdentityHeaders(deps, headers);
    const identity = await deps.verifyIdentity(headers);
    const uid = identity.uid;

    await requireNoDeletionFence(deps, uid);

    const payload = (request.body ?? {}) as { tier?: unknown };
    const requested = typeof payload.tier === "string" ? payload.tier : "";

    const settings = await getSettings({ db: deps.db });
    let plan = findPlan(settings, requested);
    const known = requested === plan.id || plan.aliases.includes(requested);
    if (!plan.enabled || !known) {
      plan = findPlan(settings, "free");
    }
    const tier = storedTier(plan);

    // Durable authority first (Ruling Q4): Postgres stores the canonical plan
    // id; Redis carries the billing alias (legacy 3x/7x/15x) the app expects.
    await deps.db.$client`
      INSERT INTO users (uid, tier) VALUES (${uid}, ${plan.id})
      ON CONFLICT (uid) DO UPDATE SET tier = EXCLUDED.tier`;
    const projection = createProjection({ db: deps.db, redis: deps.redis });
    await projection.publishUserTier(uid, tier, null);

    try {
      await reapplyUser(deps, uid);
    } catch (err) {
      console.log(`upgrade reapply error: ${errorName(err)}`);
    }
    return reply.send({ ok: true, tier });
  });

  /** GET /plans — enabled plans only (ids/aliases match user:{uid}:tier). */
  publicApp.get("/plans", async (_request, reply) => {
    const settings = await getSettings({ db: deps.db });
    return reply.send({
      plans: settings.plans
        .filter((p) => p.enabled)
        .map((p) => ({
          id: p.id,
          name: p.name,
          price_usd: p.price_usd,
          aliases: p.aliases,
          window: windowStr(p.window_hours),
        })),
    });
  });

  /**
   * GET /v1/models — forward the USER's bearer untouched and reshape the
   * catalog. Task 13 wraps this with PublicCatalog.models (image backends and
   * the image alias masked); the base version strips nothing.
   */
  publicApp.get("/v1/models", async (request, reply) => {
    const authorization = headerValue(request.headers.authorization);
    if (!/^bearer /i.test(authorization)) {
      return reply
        .code(401)
        .headers(CATALOG_HEADERS)
        .send({ error: { code: "sign_in_required" } });
    }
    try {
      const result = await deps.litellm.rawModels(authorization);
      if (result.status !== 200) {
        // Status only: never log the bearer key or the upstream body.
        console.log(`[mint] model catalog upstream status ${result.status}`);
        const mapped = catalogError(result.status, result.text);
        return reply
          .code(mapped.status)
          .headers(CATALOG_HEADERS)
          .send({ error: { code: mapped.code } });
      }
      const body = result.body as { data?: unknown } | null;
      const rows = Array.isArray(body?.data) ? body.data : [];
      const data = rows
        .filter(
          (row): row is { id: string } =>
            typeof row === "object" &&
            row !== null &&
            typeof (row as { id?: unknown }).id === "string",
        )
        .map((row) => ({ id: row.id, object: "model", owned_by: "ovid" }));
      return reply.headers(CATALOG_HEADERS).send({ object: "list", data });
    } catch (err) {
      console.log(`[mint] model catalog failed: ${errorName(err)}`);
      return reply
        .code(503)
        .headers(CATALOG_HEADERS)
        .send({ error: { code: "catalog_unavailable" } });
    }
  });
}
