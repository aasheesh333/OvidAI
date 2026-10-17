export * from "./env.js";
export * from "./auth.js";
export * from "./tickets.js";
export * from "./app.js";
export * from "./keys.js";
export * from "./wsPty.js";

import { initializeApp } from "firebase-admin/app";
import { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import { createDb, newId, byokKeysRepo, imagesRepo, sharesRepo } from "@ovid/db";
import {
  createCloudCleanup,
  createFirebaseAdmin,
  createHttpKeyAdmin,
  createLifecycle,
  createNoopR2Deleter,
  createPostgresDeletionStore,
} from "@ovid/account";
import { createRedisEventLog, createRedisSystemBus } from "@ovid/events";
import {
  createEnvelopeCrypto,
  createOAuthFlow,
  type SystemEventPublisher,
} from "@ovid/mcp";
import { createQueues } from "@ovid/queue";
import { systemEventEnvelope } from "@ovid/shared";
import { createActivityTracker, createStorage, loadStorageEnv } from "@ovid/storage";
import { buildGateway } from "./app.js";
import type { AccountRouteDeps } from "./routes/account.js";
import { createFirebaseVerifier, createTestVerifier } from "./auth.js";
import { loadGatewayEnv } from "./env.js";
import { createHttpMintProvisioner, createMintRedisKeyProvider } from "./keys.js";
import { createTicketStore } from "./tickets.js";
import { createWorkerClient } from "./workerClient.js";
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
  // be spread into garbage options by withBlockingSafeRetries. P5 Task 15:
  // opt into the plugin-installs queue (the gateway enqueues install/
  // uninstall transactions; the worker consumes them).
  const queues = createQueues({ url: cfg.redisQUrl }, { withPluginInstalls: true });
  // Tickets live in the gateway-owned Redis (REDIS_Q_URL); provisioned keys
  // are READ from mint's Redis (REDIS_MINT_URL — the URL carries the db2
  // selector, so the key provider does a plain GET).
  const redisQ = new Redis(cfg.redisQUrl);
  const redisMint = new Redis(cfg.redisMintUrl);

  // ADC / GOOGLE_APPLICATION_CREDENTIALS. Captured once: the account
  // lifecycle's Firebase Admin adapter reuses the SAME app.
  const firebaseApp =
    cfg.authMode === "firebase" ? initializeApp() : null;
  const verifier =
    firebaseApp !== null ? createFirebaseVerifier(firebaseApp) : createTestVerifier();

  // P9 Task 15: the legacy account lifecycle. It is opt-in through
  // OVID_ACCOUNT_FIREBASE_APP_IDS (no new REQUIRED gateway env): without a
  // configured App Check allowlist the adapter refuses to operate, so the
  // routes stay unregistered rather than silently accepting wrong apps.
  const accountAppIds = new Set(
    (env.OVID_ACCOUNT_FIREBASE_APP_IDS ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter((value) => value !== ""),
  );
  let account: AccountRouteDeps | undefined;
  if (firebaseApp !== null && accountAppIds.size > 0) {
    const admin = createFirebaseAdmin(firebaseApp, accountAppIds);
    const deletionStore = createPostgresDeletionStore(db);
    const lifecycle = createLifecycle({
      store: deletionStore,
      admin,
      data: createCloudCleanup({
        db,
        redisDb2: redisMint,
        redisQueue: redisQ,
        litellm: createHttpKeyAdmin(
          env.OVID_LITELLM_BASE?.trim() || "http://127.0.0.1:4000",
          env.OVID_LITELLM_MASTER_KEY?.trim() ?? "",
        ),
        r2: createNoopR2Deleter(),
        images: {
          deleteAccount: async (uid) => {
            await db.transaction(async (tx) => {
              await imagesRepo.insertDeleted(tx, uid, Math.floor(Date.now() / 1000));
              await imagesRepo.clearAccount(tx, uid);
            });
          },
        },
        shares: { deleteAccount: (uid) => sharesRepo.deleteAccount(db, uid) },
        byok: { deleteAccount: (uid) => byokKeysRepo.deleteAccount(db, uid) },
      }),
    });
    account = {
      lifecycle,
      verify: (token, attestation, opts) => admin.verify(token, attestation, opts),
    };
    if ((env.OVID_LITELLM_MASTER_KEY?.trim() ?? "") === "") {
      console.warn(
        "[gateway] account cleanup has no OVID_LITELLM_MASTER_KEY — key block/delete will fail and retry",
      );
    }
    console.warn(
      "[gateway] account cleanup R2 deleter is the no-op seam (P7 storage has no prefix-list primitive)",
    );
  } else if (cfg.authMode === "firebase") {
    console.warn(
      "[gateway] account lifecycle routes disabled — set OVID_ACCOUNT_FIREBASE_APP_IDS to enable them",
    );
  }

  // System channel hub (P5 Task 10): ONE shared sys:{uid}:out subscription
  // per uid across that uid's sockets; closed with the app below so every
  // per-uid subscriber is released on shutdown.
  const systemHub = createSystemHub(redisQ);

  // P5 Task 15: envelope crypto + the server-side MCP OAuth flow. The flow's
  // system publisher is an adapter onto the SAME hub the WS channel uses
  // (R5: one canonical systemHub field — no second channel implementation),
  // so oauth notices reach connected clients as ordinary system_event frames.
  const crypto =
    cfg.masterKey !== "" ? createEnvelopeCrypto(cfg.masterKey) : undefined;
  const systemPublisher: SystemEventPublisher = {
    publish: async (uid, event) => {
      await systemHub.publishOut(
        uid,
        systemEventEnvelope({
          id: newId(),
          kind: event.kind,
          requiresResponse: event.requiresResponse ?? false,
          payload: event.payload,
          ts: new Date().toISOString(),
        }),
      );
    },
  };
  const oauth =
    crypto !== undefined
      ? createOAuthFlow({
          db,
          crypto,
          systemBus: systemPublisher,
          redirectUri: cfg.mcpRedirectUri,
        })
      : undefined;

  // P7 Task 12: storage (presignGet for artifact URLs), the activity tracker
  // (cache-class redis — REDIS_C_URL falls back to the queue redis with one
  // warning, same dev-only fallback the worker documents), and the worker
  // file-service proxy (the gateway's only view of workspace bytes).
  const storage = createStorage(loadStorageEnv(env));
  const redisCRaw = env.REDIS_C_URL?.trim();
  const redisC =
    redisCRaw !== undefined && redisCRaw !== "" ? new Redis(redisCRaw) : redisQ;
  if (redisC === redisQ) {
    console.warn(
      "[gateway] REDIS_C_URL is not set — activity keys share REDIS_Q_URL " +
        "(dev-only; production should dedicate a cache redis)",
    );
  }
  const activity = createActivityTracker(redisC);
  const worker = createWorkerClient({
    baseUrl: cfg.workerInternalUrl,
    token: cfg.internalToken,
  });

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
      // P4 Task 11: scheduler lifecycle events (REST publishes; WS Task 12
      // subscribes) on the SAME queue Redis the worker's scheduler uses.
      system: createRedisSystemBus(redisQ),
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
      // P5 Task 15: sealed-secret crypto + the Task-9 OAuth flow (the
      // callback is registered in the public scope by app.ts).
      crypto,
      oauth,
      // Workspace surfaces (P7 Task 12): presigning, activity bumps, the
      // worker file-service proxy, and the route knobs from the environment.
      storage,
      activity,
      worker,
      inlineMaxBytes: cfg.fileInlineMaxBytes,
      putMaxBytes: cfg.putMaxBytes,
      presignTtlSeconds: cfg.presignTtlSeconds,
      hydrateWaitMs: cfg.hydrateWaitMs,
      ...(account !== undefined ? { account } : {}),
    },
    { logger: true },
  );

  // Owned connections close with the app (deploy scripts call app.close()).
  app.addHook("onClose", async () => {
    await queues.agentRuns.close();
    await queues.pluginInstalls?.close();
    await systemHub.close();
    redisQ.disconnect();
    if (redisC !== redisQ) redisC.disconnect();
    redisMint.disconnect();
    await db.$client.end({ timeout: 5 });
  });

  await app.listen({ host: cfg.host, port: cfg.port });
  return app;
}
