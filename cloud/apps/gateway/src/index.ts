export * from "./env.js";
export * from "./auth.js";
export * from "./tickets.js";
export * from "./app.js";
export * from "./keys.js";
export * from "./internalMint.js";
export * from "./wsPty.js";

import { initializeApp } from "firebase-admin/app";
import { Redis } from "ioredis";
import type { FastifyInstance } from "fastify";
import { createDb, dbPoolOptionsFromEnv, newId, byokKeysRepo, imagesRepo, sessions, sharesRepo } from "@ovid/db";
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
import { createActivityTracker, createR2PrefixDeleterFromEnv, createStorage, loadStorageEnv } from "@ovid/storage";
import { buildGateway, installShutdownHandlers } from "./app.js";
import type { AccountRouteDeps } from "./routes/account.js";
import { createFirebaseVerifier, createTestVerifier } from "./auth.js";
import { loadGatewayEnv } from "./env.js";
import { createMintModelCatalog, createMintRedisKeyProvider } from "./keys.js";
import { createInternalMintProvisioner } from "./internalMint.js";
import { createTicketStore } from "./tickets.js";
import { createWorkerClient } from "./workerClient.js";
import { createConnectionHealthClient } from "./connectionHealthClient.js";
import { createStudioGitHttpTransport } from "./studioGitHttp.js";
import { createPreviewTicketStore } from "./studioPreviewTickets.js";
import { createStudioPreviewWorkerClient } from "./studioPreviewWorkerClient.js";
import { CollabMembership, type AccountAdmission as CollabAccountAdmission } from "./collab/membership.js";
import { CollabLifecycle } from "./collab/lifecycle.js";
import { CollabProjection } from "./collab/projection.js";
import { createCollabObjectStore, createCollabReservationPort } from "./collab/objects.js";
import { withCollabDeletionFence } from "./routes/account.js";
import { createRedisPtyBridge } from "./wsPty.js";
import { createRedisApprovalPublisher, createWsSocketRegistry } from "./ws.js";
import { createSystemHub } from "./systemChannel.js";
import { DEFAULT_IP_ANOMALY_POLICY } from "./anomaly.js";
import {
  createIpAnomalyGuard,
  createIpAnomalySuspension,
} from "./ipAnomalyGuard.js";
import { createIpObservationStore } from "./ipObservations.js";
import { createRateLimiter } from "./rateLimits.js";
import { createSuspensionMailerFromEnv } from "./suspensionMailer.js";
import { createGatewayObservabilityComposition } from "./observabilityComposition.js";
import { createStdoutObservabilityExporter } from "./observabilityExporter.js";

/**
 * Composition root — intentionally untested-thin (Task 10's e2e exercises the
 * wiring): env → real deps → listen on HOST:PORT (defaults 127.0.0.1:8081;
 * container deploys set HOST=0.0.0.0). Not invoked at import — main.ts is the
 * process entry point.
 */
export async function main(env: NodeJS.ProcessEnv = process.env): Promise<FastifyInstance> {
  const cfg = loadGatewayEnv(env);

  // Task 11: real observability composition. The stdout exporter is the
  // production sink; the registry and safeLogRecord run before every sink.
  // Health probes are closures, so they can reference deps declared below.
  const observability = createGatewayObservabilityComposition({
    exporter: createStdoutObservabilityExporter(),
    health: {
      anomaly: () => ipAnomaly !== undefined,
      mail: () =>
        (env.OVID_RESEND_API_KEY?.trim() ?? "") !== "" &&
        (env.OVID_SUSPENSION_FROM_EMAIL?.trim() ?? "") !== "",
      reservation: () => collabEnabled,
      notification: () => (env.VAPID_PUBLIC_KEY?.trim() ?? "") !== "",
    },
  });

  // Audit P1 (MCP client): a server→client request racing a close rejects
  // inside fire-and-forget promise chains, and Node's default for an
  // unhandled rejection is to kill the process. Log and carry on — installed
  // at boot (never at import; index.ts stays a pure library) so it guards
  // every promise the composed app ever starts.
  process.on("unhandledRejection", (_err) => {
    observability.log({
      event: "gateway.unhandled_rejection",
      reason: "rejected_promise",
    });
  });

  // P9 Task 16: OVID_SHARE_BASE_URL is the ONLY source of receipt/viewer
  // URLs (never Host headers). It stays out of loadGatewayEnv deliberately —
  // the Python share router is unavailable without it, not misconfigured.
  const shareBaseUrl = env.OVID_SHARE_BASE_URL?.trim() ?? "";

  // Pool size: OVID_DB_POOL_MAX / OVID_DB_IDLE_TIMEOUT_S (capacity wave);
  // unset keeps the postgres.js default (10).
  const db = createDb(cfg.databaseUrl, dbPoolOptionsFromEnv(env));
  const collabEnabled = env.OVID_COLLAB_ENABLED === "true";
  const collabAuthoritySecret = env.OVID_COLLAB_AUTHORITY_SECRET?.trim() ?? "";
  if (collabEnabled && Buffer.byteLength(collabAuthoritySecret) < 32) {
    throw new Error("OVID_COLLAB_AUTHORITY_SECRET must be at least 32 bytes when OVID_COLLAB_ENABLED=true");
  }
  // Disabled rooms still need deletion fencing if the flag was previously on.
  // No route is mounted unless enabled and the token-issuing secret is configured.
  const collabDeletionMembership = new CollabMembership(db, { authoritySecret: collabAuthoritySecret });
  const collabLifecycle = new CollabLifecycle(collabDeletionMembership);
  let collabMembership = new CollabMembership(db, { authoritySecret: collabAuthoritySecret });
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
  const keyAdmin = createHttpKeyAdmin(
    env.OVID_LITELLM_BASE?.trim() || "http://127.0.0.1:4000",
    env.OVID_LITELLM_MASTER_KEY?.trim() ?? "",
  );

  // P9 final review H2: a REAL R2 prefix deleter (ListObjectsV2 +
  // DeleteObjects). The no-op seam is only kept for dev/no-R2 compositions;
  // enabling account deletion without it would report a completed deletion
  // while users/{uid}/ objects remain.
  const r2Deleter = createR2PrefixDeleterFromEnv(env);

  // ADC / GOOGLE_APPLICATION_CREDENTIALS. Captured once: the account
  // lifecycle's Firebase Admin adapter reuses the SAME app.
  const firebaseApp =
    cfg.authMode === "firebase" ? initializeApp() : null;
  const verifier =
    firebaseApp !== null
      ? createFirebaseVerifier(firebaseApp, { appCheckMode: cfg.appCheckMode })
      : createTestVerifier();
  if (cfg.authMode === "firebase" && cfg.appCheckMode !== "required") {
    observability.log({
      event: "gateway.appcheck_mode",
      outcome: cfg.appCheckMode,
      reason:
        cfg.appCheckMode === "off"
          ? "appcheck_ignored"
          : "appcheck_optional",
    });
  }

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
  let accountAdmission: CollabAccountAdmission | undefined;
  if (firebaseApp !== null && accountAppIds.size > 0) {
    if (r2Deleter === null) {
      observability.log({
        event: "gateway.account.r2_deleter_missing",
        reason: "r2_not_configured",
      });
    }
    const admin = createFirebaseAdmin(
      firebaseApp,
      accountAppIds,
      {},
      // The /account/* routes honour the same OVID_APPCHECK_MODE.
      { appCheckMode: cfg.appCheckMode },
    );
    const deletionStore = createPostgresDeletionStore(db);
    const cloudCleanup = createCloudCleanup({
      db,
      redisDb2: redisMint,
      redisQueue: redisQ,
      litellm: keyAdmin,
      r2: r2Deleter ?? createNoopR2Deleter(),
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
    });
    const lifecycle = createLifecycle({
      store: deletionStore,
      admin,
      data: withCollabDeletionFence(cloudCleanup, (uid, connection) =>
        collabLifecycle.onDeletionPending(uid, connection)),
    });
    account = {
      lifecycle,
      verify: (token, attestation, opts) => admin.verify(token, attestation, opts),
      collabLifecycle,
    };
    // Task 16's shares/reports admission seam: hold the UID lock and reject
    // every non-active/non-cancelled state. `access` only accepts ordinary
    // (non-password) identities, matching Python's admission rule.
    accountAdmission = (principal, fn) =>
      lifecycle.access(
        {
          uid: principal.uid,
          auth_time: principal.authTime,
          // Pass the verified provider through unchanged: Python's
          // `identity()` rejects a missing/unknown provider (403) rather than
          // inventing one, and `password` is not an ordinary identity.
          firebase: { sign_in_provider: principal.signInProvider },
        },
        (uid, session) => fn(uid, session),
      );
    collabMembership = new CollabMembership(db, {
      authoritySecret: collabAuthoritySecret,
      admission: accountAdmission,
    });
    if ((env.OVID_LITELLM_MASTER_KEY?.trim() ?? "") === "") {
      observability.log({
        event: "gateway.account.litellm_master_key_missing",
        reason: "missing_env",
      });
    }
    observability.log({
      event: "gateway.account.r2_deleter_noop",
      reason: "no_prefix_list",
    });
  } else if (cfg.authMode === "firebase") {
    observability.log({
      event: "gateway.account.lifecycle_disabled",
      reason: "no_firebase_app_ids",
    });
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
    observability.log({
      event: "gateway.redis.cache_url_missing",
      reason: "dev_only_fallback",
    });
  }
  const activity = createActivityTracker(redisC);
  // New runtime controls start flag-off. Enabling anomaly enforcement wires the
  // complete durable suspension path; there is no request-only "block" that
  // could masquerade as account/key suspension or fabricated mail delivery.
  const ipAnomaly = env.OVID_IP_ANOMALY_ENABLED === "true"
    ? createIpAnomalyGuard({
        store: createIpObservationStore(redisC, {
          windowMs: DEFAULT_IP_ANOMALY_POLICY.windowMs,
        }),
        trustedProxyCidrs: cfg.trustedProxyCidrs,
        suspension: createIpAnomalySuspension({
          db,
          redis: redisMint,
          keyAdmin,
          mailer: createSuspensionMailerFromEnv(env),
        }),
        onError: (_err) => {
          observability.log({
            event: "ip_anomaly.observation_degraded",
            reason: "observation_failed",
          });
        },
      })
    : undefined;
  const rateLimiter = env.OVID_RATE_LIMITS_ENABLED === "true"
    ? createRateLimiter(redisQ)
    : undefined;
  const rateLimitInternalSecret = env.OVID_RATE_LIMIT_INTERNAL_SECRET?.trim() ?? "";
  if (rateLimitInternalSecret !== "" && Buffer.byteLength(rateLimitInternalSecret) < 32) {
    throw new Error("OVID_RATE_LIMIT_INTERNAL_SECRET must be at least 32 bytes");
  }
  const worker = createWorkerClient({
    baseUrl: cfg.workerInternalUrl,
    token: cfg.internalToken,
  });
  const connectionHealthInvocations = crypto === undefined
    ? undefined
    : createConnectionHealthClient({
        baseUrl: cfg.workerInternalUrl,
        token: cfg.internalToken,
      });
  const studioGit = createStudioGitHttpTransport({
    baseUrl: cfg.workerInternalUrl,
    token: cfg.internalToken,
  });
  const studioPreviewEnv = cfg.preview;
  const studioPreview = studioPreviewEnv === undefined ||
      cfg.workerInternalUrl === "" || cfg.internalToken === ""
    ? undefined
    : (() => {
        const now = () => new Date();
        const redisKeyPrefix = "ovid:studio:preview:";
        return {
          ...studioPreviewEnv,
          worker: createStudioPreviewWorkerClient({
            baseUrl: cfg.workerInternalUrl,
            token: cfg.internalToken,
          }),
          tickets: createPreviewTicketStore(redisQ, { now, keyPrefix: redisKeyPrefix }),
          redis: redisQ,
          redisKeyPrefix,
          isSessionOwner: async (userId: string, sessionId: string) =>
            (await sessions.get(db, sessionId, userId)) !== null,
          now,
        };
      })();

  // P10 Task 2: ONE server-level registry of live WS sockets, used by the
  // SIGTERM/SIGINT drain below to close them with 1001 "server restarting".
  const wsRegistry = createWsSocketRegistry();

  const app = buildGateway(
    {
      db,
      queues,
      verifier,
      tickets: createTicketStore(redisQ),
      keys: createMintRedisKeyProvider(redisMint),
      webPushPublicKey: process.env.VAPID_PUBLIC_KEY ?? null,
      // Wave 1a: the send's `model` is validated against the mint's
      // published model groups (same mint redis as the key read).
      modelCatalog: createMintModelCatalog(redisMint),
      // Mint ensures setup AND authoritative per-send admission (quota,
      // account revocation/deletion and rate limits); never cache its verdict.
      mint: createInternalMintProvisioner(cfg.internalMintUrl, cfg.internalApiSecret),
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
      ...(cfg.cdn !== undefined ? { cdn: cfg.cdn } : {}),
      activity,
      ipAnomaly,
      rateLimiter,
      rateLimitInternalSecret,
      trustedProxyCidrs: cfg.trustedProxyCidrs,
      onRateLimitDegraded: () => {
        observability.log({
          event: "gateway.rate_limit.degraded",
          reason: "store_unavailable",
        });
      },
      worker,
      connectionHealthInvocations,
      studioGit,
      ...(studioPreview !== undefined ? { studioPreview } : {}),
      inlineMaxBytes: cfg.fileInlineMaxBytes,
      putMaxBytes: cfg.putMaxBytes,
      presignTtlSeconds: cfg.presignTtlSeconds,
      hydrateWaitMs: cfg.hydrateWaitMs,
      // P9 Task 16: legacy public paths. Shares are unavailable without the
      // configured deployment origin (Python parity); reports always mount.
      // Android package/cert env is read per request inside the share routes.
      // P9 Task 15: both carry the deletion-fence admission seam when the
      // lifecycle is configured.
      ...(shareBaseUrl !== ""
        ? {
            shares: {
              baseUrl: shareBaseUrl,
              ...(accountAdmission !== undefined ? { admission: accountAdmission } : {}),
            },
          }
        : {}),
      reports: accountAdmission !== undefined ? { admission: accountAdmission } : {},
      ...(account !== undefined ? { account } : {}),
      ...(collabEnabled ? {
        collab: {
          membership: collabMembership,
          projection: new CollabProjection(db),
          objects: createCollabObjectStore(db),
          reservations: createCollabReservationPort(db),
          orphanSweepMs: 30_000,
        },
      } : {}),
      // Task 11: live observability composition — routes/health uses the
      // health probes, and routes can emit metrics/structured logs.
      observability,
      // P10 Task 2: the shutdown drain reaches every live WS socket through
      // this registry (installShutdownHandlers below passes closeWs).
      wsRegistry,
    },
    { logger: true },
  );

  // Owned connections close with the app (deploy scripts call app.close()).
  app.addHook("onClose", async () => {
    try {
      await queues.agentRuns.close();
      await queues.pluginInstalls?.close();
      await systemHub.close();
      redisQ.disconnect();
      if (redisC !== redisQ) redisC.disconnect();
      redisMint.disconnect();
    } finally {
      // Fastify has drained requests; close only the adapter-owned lazy pool,
      // even if an earlier owned resource reported a shutdown failure.
      await keyAdmin.close?.();
      await db.$client.end({ timeout: 5 });
    }
  });

  await app.listen({ host: cfg.host, port: cfg.port });

  // P10 Task 2: SIGTERM/SIGINT drain — close WS 1001 "server restarting",
  // app.close(), hard-exit after 10 s. Installed AFTER listen so a signal
  // that races startup never sees a half-composed app.
  installShutdownHandlers(app, {
    closeWs: (code, reason) => wsRegistry.closeAll(code, reason),
  });

  return app;
}
