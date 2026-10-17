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

import { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import { createDb } from "@ovid/db";
import { buildMintApps } from "./app.js";
import { createAlerter } from "./alerts.js";
import { loadMintEnv } from "./env.js";
import { createLiteLlmAdmin } from "./litellmAdmin.js";
import { createMintVerifier } from "./verifier.js";

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

  const { publicApp, adminApp } = buildMintApps({
    db,
    redis,
    litellm,
    env: cfg,
    alerter,
    verifyIdentity: createMintVerifier(cfg),
  });

  // Owned connections close with the apps (deploy scripts call app.close()).
  publicApp.addHook("onClose", async () => {
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
