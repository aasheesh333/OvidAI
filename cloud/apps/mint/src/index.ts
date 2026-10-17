export * from "./env.js";
export * from "./litellmAdmin.js";
export * from "./alerts.js";
export * from "./app.js";

import { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import { createDb } from "@ovid/db";
import { buildMintApps, HttpContractError, type MintIdentityVerifier } from "./app.js";
import { createAlerter } from "./alerts.js";
import { loadMintEnv } from "./env.js";
import { createLiteLlmAdmin } from "./litellmAdmin.js";

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
    verifyIdentity: pendingVerifier,
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

/**
 * LOUD placeholder until Task 6 lands verifier.ts (createMintVerifier): no
 * scaffold route calls it, so it can only fire if a route is added without
 * its verifier — in which case it refuses with a contract 503 rather than
 * silently treating anyone as verified.
 */
const pendingVerifier: MintIdentityVerifier = async () => {
  throw new HttpContractError(503, "identity verifier not wired (Task 6)");
};
