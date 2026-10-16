export * from "./env.js";
export * from "./auth.js";
export * from "./tickets.js";
export * from "./app.js";
export * from "./keys.js";

import { initializeApp } from "firebase-admin/app";
import { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import { createDb } from "@ovid/db";
import { createRedisEventLog } from "@ovid/events";
import { createQueues } from "@ovid/queue";
import { buildGateway } from "./app.js";
import { createFirebaseVerifier, createTestVerifier } from "./auth.js";
import { loadGatewayEnv } from "./env.js";
import { createHttpMintProvisioner, createMintRedisKeyProvider } from "./keys.js";
import { createTicketStore } from "./tickets.js";

/**
 * Composition root — intentionally untested-thin (Task 10's e2e exercises the
 * wiring): env → real deps → listen on 127.0.0.1:PORT. Not invoked at import.
 */
export async function main(env: NodeJS.ProcessEnv = process.env): Promise<FastifyInstance> {
  const cfg = loadGatewayEnv(env);

  const db = createDb(cfg.databaseUrl);
  // createQueues takes a connection OPTIONS OBJECT — a bare URL string would
  // be spread into garbage options by withBlockingSafeRetries.
  const queues = createQueues({ url: cfg.redisQUrl });
  // Tickets live in the gateway-owned Redis (REDIS_Q_URL); provisioned keys
  // are READ from mint's Redis (REDIS_MINT_URL — the URL carries the db2
  // selector, so the key provider does a plain GET).
  const redisQ = new Redis(cfg.redisQUrl);
  const redisMint = new Redis(cfg.redisMintUrl);

  const verifier =
    cfg.authMode === "firebase"
      ? createFirebaseVerifier(initializeApp()) // ADC / GOOGLE_APPLICATION_CREDENTIALS
      : createTestVerifier();

  const app = buildGateway(
    {
      db,
      queues,
      verifier,
      tickets: createTicketStore(redisQ),
      keys: createMintRedisKeyProvider(redisMint),
      mint: createHttpMintProvisioner(cfg.mintBaseUrl),
      // Session event log shares the queue Redis; the worker (Task 9) appends
      // to the same instance, so gateway replay/live sees every event.
      events: createRedisEventLog(redisQ),
    },
    { logger: true },
  );

  // Owned connections close with the app (deploy scripts call app.close()).
  app.addHook("onClose", async () => {
    await queues.agentRuns.close();
    redisQ.disconnect();
    redisMint.disconnect();
    await db.$client.end({ timeout: 5 });
  });

  await app.listen({ host: "127.0.0.1", port: cfg.port });
  return app;
}
