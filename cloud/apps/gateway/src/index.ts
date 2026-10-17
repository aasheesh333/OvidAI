export * from "./env.js";
export * from "./auth.js";
export * from "./tickets.js";
export * from "./app.js";
export * from "./keys.js";
export * from "./wsPty.js";

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
import { createRedisPtyBridge } from "./wsPty.js";
import { createRedisApprovalPublisher } from "./ws.js";
import { createSystemHub } from "./systemChannel.js";

/**
 * Composition root — intentionally untested-thin (Task 10's e2e exercises the
 * wiring): env → real deps → listen on HOST:PORT (defaults 127.0.0.1:8081;
 * container deploys set HOST=0.0.0.0). Not invoked at import — main.ts is the
 * process entry point.
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

  // System channel hub (P5 Task 10): ONE shared sys:{uid}:out subscription
  // per uid across that uid's sockets; closed with the app below so every
  // per-uid subscriber is released on shutdown.
  const systemHub = createSystemHub(redisQ);

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
      // Terminal-over-WS bridge (Task 13): ctl/out pub-sub + the pty registry
      // all live on the same queue Redis the worker PSUBSCRIBEs.
      pty: createRedisPtyBridge(redisQ),
      // Browser viewer channel (P6 Task 9): each attach opens its own
      // dedicated ctl/input publisher + frames/state subscriber on the queue
      // Redis (the worker's browser bridge subscribes the matching channels).
      browser: { redisFactory: () => new Redis(cfg.redisQUrl) },
      // Approval responses (P3 Task 12): the ws dispatch publishes the
      // client's approval_response frames to the queue Redis; the worker's
      // approval bridge subscribes the same channel.
      approvals: createRedisApprovalPublisher(redisQ),
      // System channel (P5 Task 10): ONE shared sys:{uid}:out subscription
      // per uid across that uid's sockets (mcp approvals / elicitation /
      // plugin progress / oauth notices); client responses go back on
      // sys:{uid}:in.
      systemHub,
    },
    { logger: true },
  );

  // Owned connections close with the app (deploy scripts call app.close()).
  app.addHook("onClose", async () => {
    await queues.agentRuns.close();
    await systemHub.close();
    redisQ.disconnect();
    redisMint.disconnect();
    await db.$client.end({ timeout: 5 });
  });

  await app.listen({ host: cfg.host, port: cfg.port });
  return app;
}
