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
import { buildMintApps, type MintDeps } from "./app.js";
import { createAlerter } from "./alerts.js";
import { createBillingService } from "./billing/service.js";
import { loadMintEnv } from "./env.js";
import { createLiteLlmAdmin } from "./litellmAdmin.js";
import { createProjection } from "./projection.js";
import { createMintVerifier } from "./verifier.js";
import { reapplyUser } from "./windows.js";

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
