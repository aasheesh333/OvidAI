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
import { createDb, accountDeletions } from "@ovid/db";
import { money } from "@ovid/money";
import { buildMintApps, type MintDeps } from "./app.js";
import { createAlerter } from "./alerts.js";
import { startMintBackgroundLoops } from "./background.js";
import { createBillingService } from "./billing/service.js";
import { setModelCatalogProjection } from "./catalog.js";
import { loadMintEnv } from "./env.js";
import { createAdmission } from "./images/admission.js";
import { registerImagesAdminRoutes } from "./images/adminRoutes.js";
import { CardManager, Discovered, createLiveCatalogProjection } from "./images/cardManager.js";
import { createCardStore } from "./images/cardStore.js";
import { catalogHash, publicCard, supports } from "./images/capabilities.js";
import { parseModelInfo, PriceBook } from "./images/costing.js";
import { createDirectEdit } from "./images/directEdit.js";
import { createImageLedger } from "./images/ledger.js";
import { LiteLLMProbeTransport, ProbeRunner } from "./images/probes.js";
import {
  alternatives,
  missing,
  parseModel,
  pickBackends,
  taskFromRequest,
} from "./images/routing.js";
import { registerImagesRoutes } from "./images/routes.js";
import {
  createLiteLlmImageService,
  type ImageBackend,
} from "./images/service.js";
import { IMAGE_ALIAS } from "./images/types.js";
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
 * Image model discovery from LiteLLM `/model/info` (port of
 * images_gateway._Discovery.discovered).
 *
 * Only identity fields are kept; credentials are never stored. A model is
 * tagged `edit_transport: "direct"` only when the direct JSON transport is
 * actually enabled for its discovered api_base — otherwise hints + probes
 * decide instead of forcing "edit unsupported".
 *
 * `edit_transport` is never copied from `litellm_params` (matching Python's
 * `_Discovery`): a configured `"direct"` must not outlive the key/host gate,
 * or a card would persist a direct marker whose call can never succeed and
 * would hold a reservation on a doomed request. Only an explicit `"none"` is
 * preserved; everything else derives solely from `enabled_for()`.
 */
export function imageDiscoveredFromModelInfo(
  rows: ModelInfoRow[],
  directEdit: ReturnType<typeof createDirectEdit>,
): Discovered[] {
  const out: Discovered[] = [];
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
    const params = row.litellm_params ?? {};
    const identity: Record<string, unknown> = {};
    for (const key of ["model", "api_base", "custom_llm_provider"]) {
      const value = params[key];
      if (value !== undefined && value !== null && value !== "") identity[key] = value;
    }
    if (params.edit_transport === "none") {
      identity.edit_transport = "none";
    } else if (directEdit.enabled_for(identity)) {
      identity.edit_transport = "direct";
    }
    out.push(new Discovered(name, identity, info));
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

  // Task 18: the images mount. Python always mounts it, defaulting the
  // upstream bound to 1.00 (images_gateway.py:
  // `os.environ.get("OVID_IMAGE_MAX_UPSTREAM_USD", "1.00")`). The bound is
  // validated below; an invalid value aborts the boot.
  const images = await buildImagesMount(mintDeps, cfg, litellm, adminApp);
  registerImagesRoutes(publicApp, mintDeps, images.service, images.admission);
  // L5 (T13 review): the private-name projection must track discovery, not a
  // boot-time snapshot. This hook runs AFTER registerImagesRoutes' onReady
  // (hooks execute in registration order), replacing its snapshot.
  publicApp.addHook("onReady", async () => {
    setModelCatalogProjection(createLiveCatalogProjection(images.manager, () => true));
  });

  // Task 18 Step 3 (owner-gated Q1): installed-base first boot.
  // `import-first` copies live db2 state into Postgres (insert-if-absent,
  // never deletes Redis keys) BEFORE the authoritative resync can overwrite
  // it. A failed import aborts the boot: continuing would let resync write
  // Postgres-derived (empty) state over the live projection.
  if (cfg.projectionMode === "import-first") {
    try {
      const imported = await projection.importFromRedisOnce();
      console.log(
        `[mint] projection import-first: ${imported.imported.users} users, ` +
          `plans=${imported.imported.plans}, settings=${imported.imported.settings}`,
      );
    } catch (err) {
      throw new Error(
        `[mint] projection import-first failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }

  // I3: reconcile the Redis db2 projection with the Postgres authority at
  // boot. A failed admin projection write (Postgres committed, Redis did
  // not) is repaired here on the next restart. Redis being down must not
  // prevent the process from starting — the hook will recover when Redis
  // returns, and the durable state is already correct.
  try {
    const report = await projection.resyncAtBoot();
    console.log(
      `[mint] projection resync (${cfg.projectionMode}): ${report.rewritten.length} rewritten, ` +
        `${report.identical} identical, ${report.conflictsResolvedFromPostgres} conflicts resolved`,
    );
  } catch (err) {
    console.log(
      `[mint] projection resync failed: ${err instanceof Error ? err.name : String(err)}`,
    );
  }

  // Task 7/18: the sweeper (slow-mode drain + catalog refresh) and the spend
  // monitor run inside the mint process, exactly like Python's daemon threads.
  const background = startMintBackgroundLoops(mintDeps);

  // Owned connections close with the apps (deploy scripts call app.close()).
  publicApp.addHook("onClose", async () => {
    images.manager.stop();
    await background.stop();
    redis.disconnect();
    await db.$client.end({ timeout: 5 });
  });

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
 * Build the Task-14 images mount: the capability CardManager (discovery,
 * extraction, budget-capped probes), the service/admission bridge, the
 * owner-only admin routes, and the background worker. The upstream bound
 * defaults to Python's 1.00 when OVID_IMAGE_MAX_UPSTREAM_USD is unset.
 */
async function buildImagesMount(
  mintDeps: MintDeps,
  cfg: ReturnType<typeof loadMintEnv>,
  litellm: LiteLlmAdmin,
  adminApp: FastifyInstance,
): Promise<{
  service: ReturnType<typeof createLiteLlmImageService>;
  admission: ReturnType<typeof createAdmission>;
  manager: CardManager;
}> {
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
  const directEdit = createDirectEdit(cfg);
  const fetchImpl = mintDeps.fetchImpl ?? fetch;

  // Background-only discovery + provider metadata fetch (never on a request
  // path). The CardManager owns the cache; request paths read manager.cards().
  const discover = async (): Promise<Discovered[]> =>
    imageDiscoveredFromModelInfo(await litellm.modelInfo(), directEdit);
  const fetchJson = async (url: string): Promise<unknown> => {
    try {
      const response = await fetchImpl(url, {
        redirect: "manual",
        signal: AbortSignal.timeout(15_000),
      });
      if (response.status !== 200) return null;
      const text = await response.text();
      if (text.length > 8 * 1024 * 1024) return null;
      return JSON.parse(text);
    } catch {
      return null;
    }
  };

  const store = createCardStore(mintDeps.db);
  // Without the dedicated probe key cards stay static (Python parity).
  const probeKey = cfg.images.probeKey;
  const runner: ProbeRunner | null =
    probeKey === null || probeKey === ""
      ? null
      : new ProbeRunner(
          new LiteLLMProbeTransport(cfg.litellmBaseUrl, probeKey, {
            masterKey: cfg.litellmMasterKey,
            direct: {
              enabled_for: (params) => directEdit.enabled_for(params),
              post: (params, prompt, size, imageDataUrl) =>
                directEdit.post(params, prompt, size, imageDataUrl),
              settlementCost: (responseJson, bound) =>
                directEdit.settlementCost(responseJson, bound),
              editCost:
                cfg.images.editCostUsd === null
                  ? null
                  : Number(cfg.images.editCostUsd),
            },
            paramsFor: (model: string): Record<string, unknown> | null =>
              manager.paramsFor(model),
          }),
          store,
          {
            perProbeCap: cfg.images.probeMaxUsd,
            dailyCap: cfg.images.probeDailyUsd,
            maxSizes: cfg.images.probeMaxSizes,
          },
        );
  const manager: CardManager = new CardManager(store, runner, {
    fetchJson,
    ttl: cfg.images.probeTtlS,
    probeGap: cfg.images.probeStaggerS,
  });
  await manager.load();
  // One discovery read at boot so the first request sees the models; a
  // LiteLLM outage leaves the mount empty until the worker retries.
  try {
    manager.observe(await discover());
  } catch (err) {
    console.log(
      `[mint] image discovery failed at boot: ${err instanceof Error ? err.name : String(err)}`,
    );
  }
  // Extraction/probes run here, never on a user request path.
  manager.start(discover, 60);

  const service = createLiteLlmImageService({
    ledger,
    backends: () =>
      manager.cards().map((card): ImageBackend => ({
        model: card.model,
        sizes: card.sizes.native,
        edit: supports(card, "edit"),
        card,
        params: manager.paramsFor(card.model) ?? {},
      })),
    cards: () => manager.cards(),
    directEdit,
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
    // The exact capabilities.py/routing.py port (Task 14 M2).
    routing: {
      parseModel,
      taskFromRequest,
      missing,
      pickBackends,
      alternatives,
      publicCard,
      catalogHash,
    },
  });
  const admission = createAdmission({
    effectiveTier: (uid) => effectiveTier(mintDeps, uid),
    tierBudget: (uid, tier) => tierBudget(mintDeps, uid, tier),
    freeCapRemaining: (uid) => freeCapRemaining(mintDeps, uid),
    // P9 final review H1: the same tombstone rule as /mint, /upgrade and
    // /internal/mint-key (cancelled/active never fence).
    deletionPending: async (uid) => {
      const row = await accountDeletions.get(mintDeps.db, uid);
      return row !== null && row.state !== "cancelled" && row.state !== "active";
    },
    keySpend: async (keyId) => {
      const info = await litellm.keyInfo(keyId);
      const spend = info?.spend;
      return typeof spend === "number" && Number.isFinite(spend) ? spend : null;
    },
  });
  registerImagesAdminRoutes(adminApp, mintDeps, manager, {
    wake: () => manager.wake(),
    refreshPrices: async () => {
      await priceBook.refresh();
      try {
        manager.observe(await discover());
      } catch {
        // A failed refresh keeps the previous discovery; the TTL retries.
      }
      manager.wake();
    },
  });
  return { service, admission, manager };
}
