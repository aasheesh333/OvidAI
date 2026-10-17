export * from "./env.js";
export * from "./litellmAdmin.js";
export * from "./alerts.js";
export * from "./app.js";
// Task 4: settings authority (Postgres) + the Redis db2 projection + the
// ovid_plans math port shared with the (unmodified) Python pools hook.
export * from "./planMath.js";
export * from "./settings.js";
export * from "./projection.js";
// Task 5: window/budget machinery, the /usage contract and the model catalog.
export * from "./windows.js";
export * from "./usage.js";
export * from "./catalog.js";
// Task 6: the public mint surface — verifier, idempotent key minting, routes.
export * from "./verifier.js";
export * from "./keyMint.js";
export * from "./mintRoutes.js";
// Task 8: the owner admin console + /admin/* JSON API and audit trail.
export * from "./adminAudit.js";
export * from "./adminRoutes.js";
// Task 10: Play Billing — verify/RTDN, the durable ledger, tier sink.
export * from "./billing/domain.js";
export * from "./billing/products.js";
export * from "./billing/play.js";
export * from "./billing/service.js";
export * from "./billing/routes.js";
// NOTE: billing/tierSink.ts is intentionally not star-exported — it declares
// TIER_SKEW_SECONDS, which projection.ts already exports (the same constant).

import { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import { createDb } from "@ovid/db";
import { money } from "@ovid/money";
import { buildMintApps, type MintDeps } from "./app.js";
import { createAlerter } from "./alerts.js";
import { createBillingService } from "./billing/service.js";
import { loadMintEnv } from "./env.js";
import { createAdmission } from "./images/admission.js";
import { parseModelInfo, PriceBook } from "./images/costing.js";
import { createDirectEdit } from "./images/directEdit.js";
import { createImageLedger } from "./images/ledger.js";
import { registerImagesRoutes } from "./images/routes.js";
import {
  createLiteLlmImageService,
  type ImageBackend,
} from "./images/service.js";
import { IMAGE_ALIAS, SIZES } from "./images/types.js";
import { createLiteLlmAdmin, type LiteLlmAdmin, type ModelInfoRow } from "./litellmAdmin.js";
import { createProjection } from "./projection.js";
import { createMintVerifier } from "./verifier.js";
import {
  effectiveTier,
  freeCapRemaining,
  reapplyUser,
  tierBudget,
} from "./windows.js";

/**
 * Image backend discovery from LiteLLM `/model/info`.
 *
 * Task 14's CardManager (capability cards + probing) has not landed on this
 * branch. Until it does, the mount derives the Task-13 `ImageBackend` rows
 * from LiteLLM's image-kind deployments and lets the service build legacy
 * cards (generate/edit, SIZES). The `cards` seam is intentionally left unset:
 * when T14 lands, replace `backends`/`cards` here with the CardManager — no
 * other wiring changes.
 */
function imageBackendsFromModelInfo(rows: ModelInfoRow[]): ImageBackend[] {
  const out: ImageBackend[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    const name = typeof row.model_name === "string" ? row.model_name.trim() : "";
    if (name === "" || name === IMAGE_ALIAS || seen.has(name)) continue;
    const info = row.model_info ?? {};
    const modality = info.output_modality;
    const imageKind =
      modality === "image" ||
      (Array.isArray(modality) && modality.includes("image")) ||
      info.mode === "image_generation";
    if (!imageKind) continue;
    const declared = Array.isArray(info.supported_sizes)
      ? info.supported_sizes.filter(
          (size): size is string =>
            typeof size === "string" && (SIZES as readonly string[]).includes(size),
        )
      : [];
    out.push({
      model: name,
      sizes: declared.length > 0 ? declared : SIZES,
      // The Python config marks every configured image backend edit-capable;
      // the direct-edit transport re-checks the discovered api_base host.
      edit: true,
      params: row.litellm_params ?? {},
    });
    seen.add(name);
  }
  return out;
}

/** Android key first, then web — the same namespace order as poolUserKeyIds. */
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
 * Composition root — intentionally untested-thin (later e2e tasks exercise
 * the wiring): env → real deps → two listeners (public 8091 / admin 8092).
 * Not invoked at import — main.ts is the process entry point.
 */
export async function main(
  env: NodeJS.ProcessEnv = process.env,
): Promise<{ publicApp: FastifyInstance; adminApp: FastifyInstance }> {
  const cfg = loadMintEnv(env);

  const db = createDb(cfg.databaseUrl);
  // The URL itself carries the db selector (prod …/2) — plain connection.
  const redis = new Redis(cfg.redisDb2Url);
  const litellm = createLiteLlmAdmin(cfg.litellmBaseUrl, cfg.litellmMasterKey);
  const alerter = createAlerter(redis, cfg);
  const projection = createProjection({ db, redis });
  const verifyIdentity = createMintVerifier(cfg);

  // Task 10 wiring: build the billing service on the SAME deps and hand it to
  // buildMintApps, which registers /billing/* and merges the billing fields
  // into /usage. With no OVID_PLAY_SERVICE_ACCOUNT_FILE the service is
  // unconfigured and answers 503 billing_unavailable (the intended gate).
  const mintDeps: MintDeps = {
    db,
    redis,
    litellm,
    env: cfg,
    alerter,
    verifyIdentity,
  };
  mintDeps.billing = createBillingService({
    db,
    redis,
    env: cfg,
    projection,
    reapplyUser: (uid: string) => reapplyUser(mintDeps, uid),
  });

  const { publicApp, adminApp } = buildMintApps(mintDeps);

  // Task 13: the images mount. Python always mounts it, defaulting the
  // upstream bound to 1.00 (images_gateway.py:
  // `os.environ.get("OVID_IMAGE_MAX_UPSTREAM_USD", "1.00")`). The bound is
  // validated below; an invalid value aborts the boot.
  const images = buildImagesMount(mintDeps, cfg, litellm);
  registerImagesRoutes(publicApp, mintDeps, images.service, images.admission);

  // Owned connections close with the apps (deploy scripts call app.close()).
  publicApp.addHook("onClose", async () => {
    redis.disconnect();
    await db.$client.end({ timeout: 5 });
  });

  // I3: reconcile the Redis db2 projection with the Postgres authority at
  // boot. A failed admin projection write (Postgres committed, Redis did
  // not) is repaired here on the next restart. Redis being down must not
  // prevent the process from starting — the hook will recover when Redis
  // returns, and the durable state is already correct.
  try {
    const report = await createProjection({ db, redis }).resyncAtBoot();
    console.log(
      `[mint] projection resync: ${report.rewritten.length} rewritten, ` +
        `${report.identical} identical, ${report.conflictsResolvedFromPostgres} conflicts resolved`,
    );
  } catch (err) {
    console.log(
      `[mint] projection resync failed: ${err instanceof Error ? err.name : String(err)}`,
    );
  }

  await publicApp.listen({ host: cfg.host, port: cfg.publicPort });
  try {
    await adminApp.listen({ host: cfg.host, port: cfg.adminPort });
  } catch (err) {
    await publicApp.close();
    throw err;
  }
  return { publicApp, adminApp };
}

/**
 * Build the Task-13 images service + admission bridge. The upstream bound
 * defaults to Python's 1.00 when OVID_IMAGE_MAX_UPSTREAM_USD is unset. The
 * `cards` seam stays unset until Task 14's CardManager lands (legacy cards
 * are derived from the backends).
 */
function buildImagesMount(
  mintDeps: MintDeps,
  cfg: ReturnType<typeof loadMintEnv>,
  litellm: LiteLlmAdmin,
): {
  service: ReturnType<typeof createLiteLlmImageService>;
  admission: ReturnType<typeof createAdmission>;
} {
  const raw = cfg.images.maxUpstreamCostUsd ?? "1.00";
  let maxUpstreamCost;
  try {
    maxUpstreamCost = money(raw);
  } catch {
    throw new Error(`OVID_IMAGE_MAX_UPSTREAM_USD must be a decimal, got: ${raw}`);
  }
  if (!maxUpstreamCost.greaterThan(0)) {
    throw new Error(`OVID_IMAGE_MAX_UPSTREAM_USD must be positive, got: ${raw}`);
  }

  const ledger = createImageLedger(mintDeps.db);
  const priceBook = new PriceBook(async () =>
    parseModelInfo(await litellm.modelInfo()),
  );
  const service = createLiteLlmImageService({
    ledger,
    backends: async () => imageBackendsFromModelInfo(await litellm.modelInfo()),
    directEdit: createDirectEdit(cfg),
    fetchImpl: mintDeps.fetchImpl,
    litellmBaseUrl: cfg.litellmBaseUrl,
    maxUpstreamCost,
    priceBook,
    userKey: (uid) => firstUserKey(mintDeps.redis, uid, "key"),
    userKeyId: (uid) => firstUserKey(mintDeps.redis, uid, "keyid"),
    keySpend: async (keyId) => {
      const info = await litellm.keyInfo(keyId);
      const spend = info?.spend;
      return typeof spend === "number" && Number.isFinite(spend) ? spend : null;
    },
  });
  const admission = createAdmission({
    effectiveTier: (uid) => effectiveTier(mintDeps, uid),
    tierBudget: (uid, tier) => tierBudget(mintDeps, uid, tier),
    freeCapRemaining: (uid) => freeCapRemaining(mintDeps, uid),
    keySpend: async (keyId) => {
      const info = await litellm.keyInfo(keyId);
      const spend = info?.spend;
      return typeof spend === "number" && Number.isFinite(spend) ? spend : null;
    },
  });
  return { service, admission };
}
