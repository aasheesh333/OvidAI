import Fastify, {
  type FastifyError,
  type FastifyInstance,
  type FastifyRequest,
  type FastifyServerOptions,
} from "fastify";
import websocket from "@fastify/websocket";
import type { Db } from "@ovid/db";
import type { EventLog, SystemBus } from "@ovid/events";
import type { ConnectionHealthInvocations, EnvelopeCrypto, OAuthFlow } from "@ovid/mcp";
import type { QueueServices } from "@ovid/queue";
import type { InternalMintProvisioner, KeyProvider } from "@ovid/shared";
import type { ApiError } from "@ovid/shared";
import type { ActivityTracker, CdnConfig, StorageAdapter } from "@ovid/storage";
import { authHook, type Verifier } from "./auth.js";
import { registerAccountRoutes, type AccountRouteDeps } from "./routes/account.js";
import { registerArtifactCdnRoutes, registerCdnGrantRoutes } from "./routes/artifactCdn.js";
import { registerArtifactRoutes } from "./routes/artifacts.js";
import { registerArtifactVaultRoutes } from "./routes/artifactVault.js";
import { registerAttachmentRoutes } from "./routes/attachments.js";
import { registerCredentialRoutes } from "./routes/credentials.js";
import type { AttachmentPresigner } from "./routes/attachments.js";
import { registerByokRoutes } from "./routes/byok.js";
import type { ByokRouteOverrides } from "./routes/byok.js";
import type { GithubRouteOverrides } from "./studioGithub.js";
import type { StudioGitTransport } from "./studioGit.js";
import {
  isStudioPreviewOriginPath,
  registerStudioPreviewApiRoutes,
  registerStudioPreviewOriginRoot,
  type StudioPreviewGatewayConfig,
} from "./studioPreviewGateway.js";
import { registerDevicesRoutes } from "./routes/devices.js";
import { registerWebPushRoutes } from "./routes/webPush.js";
import { registerUsageHistoryRoutes } from "./routes/usageHistory.js";
import { registerEventRoutes } from "./routes/events.js";
import { registerHealthRoutes } from "./routes/health.js";
import { registerImportRoutes } from "./routes/import.js";
import { registerMcpCatalogRoutes } from "./routes/mcpCatalog.js";
import {
  registerMcpOauthCallbackRoutes,
  registerMcpOauthPublicCallbackRoute,
  registerMcpOauthRoutes,
} from "./routes/mcpOauth.js";
import { registerMcpServerRoutes, type ConnectionHealthAdapter } from "./routes/mcpServers.js";
import { registerMessageRoutes } from "./routes/messages.js";
import { registerModelRoutes } from "./routes/models.js";
import { registerPlanRoutes } from "./routes/plans.js";
import { registerBillingEntitlementRoutes } from "./routes/billingEntitlement.js";
import { registerSearchRoutes } from "./routes/search.js";
import { registerAccountHealthRoutes } from "./routes/accountHealth.js";
import { registerDataControlRoutes } from "./routes/dataControl.js";
import {
  registerAccountSettingsRoutes,
  registerPreferenceRoutes,
} from "./routes/accountSettings.js";
import { registerMemoryRoutes } from "./routes/memory.js";
import { registerPluginRoutes } from "./routes/plugins.js";
import { registerProjectRoutes } from "./routes/projects.js";
import { registerReportsRoutes } from "./routes/reports.js";
import type { ReportsConfig } from "./routes/reports.js";
import { registerRunRoutes } from "./routes/runs.js";
import { registerScheduleRoutes } from "./routes/schedules.js";
import { registerStudioRoutes } from "./routes/studio.js";
import { registerSessionRoutes } from "./routes/sessions.js";
import { registerSystemResponseRoutes } from "./routes/systemResponses.js";
import { registerSystemRequestRoutes } from "./routes/systemRequests.js";
import { registerSharesRoutes } from "./shares/routes.js";
import type { SharesConfig } from "./shares/routes.js";
import { registerWorkspaceRoutes } from "./routes/workspace.js";
import { registerWsRoute } from "./routes/wsRoute.js";
import type { TicketStore } from "./tickets.js";
import type { WorkerClient } from "./workerClient.js";
import type { ApprovalPublisher, WsDeps, WsSocketRegistry } from "./ws.js";
import type { BrowserChannelDeps } from "./browserChannel.js";
import { PtyBridgeError, type PtyBridge } from "./wsPty.js";
import type { SystemHub } from "./systemChannel.js";
import type { IpAnomalyGuard } from "./ipAnomalyGuard.js";
import { registerCollabRoutes } from "./collab/routes.js";
import type { CollabMembership } from "./collab/membership.js";
import type { createGatewayObservabilityComposition } from "./observabilityComposition.js";
import type { CollabProjection } from "./collab/projection.js";
import type { CollabLongPollOptions } from "./collab/longPoll.js";
import {
  createCollabObjectStore,
  createCollabReservationPort,
  registerCollabObjectRoutes,
  type CollabObjectStore,
  type CollabReservationPort,
  type CollabReservedRelease,
} from "./collab/objects.js";
import {
  createRateLimitPreHandler,
  registerRateLimitInternalRoute,
  type RateLimiter,
} from "./rateLimits.js";

export interface GatewayDeps {
  db: Db;
  queues: QueueServices;
  verifier: Verifier;
  tickets: TicketStore;
  keys: KeyProvider;
  /**
   * P9 Task 9: server-to-server key provisioning. The gateway signs its OWN
   * verified principal (`ensureKeyForUid(uid)`) — the caller's Firebase
   * token is never forwarded to mint.
   */
  mint: InternalMintProvisioner;
  /** Session event log (Task 4) — the WS channel's replay + live source. */
  events: EventLog;
  /**
   * P4 Task 11: the per-user scheduler system bus. REST schedule mutations
   * publish lifecycle events on `user:{uid}:system`; the WS system channel
   * (Task 12) subscribes the same bus. The composition root wires
   * createRedisSystemBus(redisQ). REQUIRED: the schedule routes have no
   * silent no-op fallback — a composition without it must fail to typecheck
   * rather than drop notifications.
   */
  system: SystemBus;
  /**
   * Terminal-over-WS bridge (Task 13). main() always wires
   * createRedisPtyBridge(redisQ). The field is OPTIONAL only so the P1
   * compositions (spine e2e + P1 suites) stay source-compatible: when absent,
   * the WS channel answers every pty frame with an `internal` error frame
   * instead of crashing — the fallback is loud, never a silent no-op.
   */
  pty?: PtyBridge;
  /**
   * P6 Task 9: the browser viewer channel's redis factory (each attach opens
   * a dedicated ctl/input publisher + a frames/state subscriber). main()
   * wires `{ redisFactory: () => new Redis(cfg.redisQUrl) }`. OPTIONAL only
   * so pre-P6 compositions (spine e2e + P1 suites) stay source-compatible;
   * when absent, every browser_* frame answers a loud `unavailable` error
   * frame instead of crashing — the fallback is loud, never a silent no-op.
   */
  browser?: BrowserChannelDeps;
  /**
   * P3 Task 12: the approval-responses publisher (the ws dispatch's only
   * view of the approval channel). main() always wires
   * createRedisApprovalPublisher(redisQ). OPTIONAL only so pre-P3
   * compositions (spine e2e + P1 suites) stay source-compatible; when
   * absent, every approval_response frame answers a loud `unavailable`
   * error frame instead of crashing — the fallback is loud, never a silent
   * no-op.
   */
  approvals?: ApprovalPublisher;
  /**
   * P5 Task 10: the system channel hub (the ws dispatch's only view of the
   * system events channel). main() always wires createSystemHub(redisQ).
   * R5 (binding): this is the ONE canonical field name for the dependency —
   * Task 15 consumes the SAME `systemHub` field; no second `system:`/`hub:`
   * alias is ever added. OPTIONAL only so pre-P5 compositions (spine e2e +
   * P1 suites) stay source-compatible; when absent, every connection skips
   * the system attach and an incoming system_response answers a loud
   * `bad_message` error frame instead of crashing.
   */
  systemHub?: SystemHub;
  /**
   * P8 Task 3: presigned-PUT seam for attachment uploads (ruling P8-Q3 —
   * structurally @ovid/storage's StorageAdapter.presignPut, so the R2 adapter
   * satisfies it as-is). OPTIONAL only so pre-P8 compositions (spine e2e + P1
   * suites) stay source-compatible; when absent the attachments route answers
   * a loud 503 attachments_not_configured instead of silently no-opping. The
   * composition root wires it.
   */
  presigner?: AttachmentPresigner;
  /**
   * P7 Task 12: storage adapter (presignGet) for artifact download URLs.
   * OPTIONAL only so pre-P7 compositions (spine e2e + P1 suites) stay
   * source-compatible; when absent the artifact URL route answers a loud 503
   * storage_not_configured instead of silently no-opping. main() wires
   * createStorage(loadStorageEnv(env)).
   */
  storage?: StorageAdapter;
  /**
   * W12: signed-token CDN acceleration (OVID_CDN_BASE_URL +
   * OVID_CDN_SIGNING_SECRET). OPTIONAL: absent means the CDN routes answer a
   * typed 503 cdn_not_configured and clients fall back to `storage.presignGet`
   * — enabling or disabling the CDN never breaks artifact access.
   */
  cdn?: CdnConfig;
  /**
   * P7 Task 12: session activity tracker — the Studio-interaction signal the
   * hibernator consults. OPTIONAL for the same composition-compat reason;
   * when absent bumps are skipped with ONE server-side warning (a read must
   * never fail over a missing auxiliary dep). main() wires
   * createActivityTracker(redisC).
   */
  activity?: ActivityTracker;
  /**
   * IP fan-out admission for POST /sessions/:id/messages. The enabled composition
   * wires a Redis-backed observation store + the pure decision function; a block
   * refuses the send (typed 403 ip_anomaly_blocked) BEFORE ownership, body
   * validation, mint, writes or enqueue.
   *
   * OPTIONAL for pre-existing compositions and the rollout flag. ABSENT = the
   * check is skipped; main wires the complete durable suspension path only
   * when OVID_IP_ANOMALY_ENABLED=true. The guard fails OPEN on an observation
   * Redis outage (`store_unavailable`), with explicit degraded telemetry.
   */
  ipAnomaly?: IpAnomalyGuard;
  /** Durable Redis UID/IP buckets. Optional for flag-off/legacy compositions. */
  rateLimiter?: RateLimiter;
  /** Independent Web-edge signature secret; never the mint signing secret. */
  rateLimitInternalSecret?: string;
  /** Verified Caddy/Cloudflare peers for direct-client forwarding headers. */
  trustedProxyCidrs?: readonly string[];
  /** Explicit degraded-store telemetry; a failure is never a healthy allow. */
  onRateLimitDegraded?: (error: unknown) => void;
  /**
   * P7 Task 12: the worker file-service proxy — the gateway's only view of
   * workspace bytes. OPTIONAL for the same composition-compat reason; when
   * absent every workspace tree/file route answers a loud 503
   * file_service_not_configured. main() wires
   * createWorkerClient({ baseUrl: workerInternalUrl, token: internalToken }).
   */
  worker?: WorkerClient;
  /**
   * P7 Task 12 knobs (defaults resolved inside the routes when absent):
   * inlineMaxBytes mirrors the WORKER's inline cap (the worker owns the
   * inline-vs-redirect decision — kept for composition parity); putMaxBytes
   * caps a PUT's decoded content; presignTtlSeconds signs artifact URLs;
   * hydrateWaitMs bounds PUT's wait for a cold workspace to warm.
   */
  inlineMaxBytes?: number;
  putMaxBytes?: number;
  presignTtlSeconds?: number;
  hydrateWaitMs?: number;
  /** Public half of Web Push VAPID; private half stays only on the worker. */
  webPushPublicKey?: string | null;
  /**
   * Reserved for time-sensitive logic (Task 8 WS heartbeats, TTL math); the
   * REST routes deliberately use DB time (repos) so pagination and ordering
   * never depend on gateway clocks. (The attachments route's expiresAt is the
   * one deliberate exception: it mirrors the presigner TTL, not row state.)
   */
  clock?: () => Date;
  /**
   * P10 Task 2: bounded deadline (ms) on the internal-mint key-provisioning
   * call in POST /sessions/:id/messages. Default 10000. A timeout answers
   * 503 `unavailable` (bounded), never a hung request.
   */
  mintTimeoutMs?: number;
  /**
   * Wave 1a (CH-007): the model catalog a send's `model` is validated against
   * (LiteLLM model-group names). Production reads the mint's published
   * `config:model_groups` list from the mint redis. There is no per-plan
   * model restriction: every plan may use every catalog model (allowances are
   * price-based — ovid_plans "only price matters"). Absent, null or throwing
   * = catalog unknown → the id is accepted (documented fail-open; the
   * LiteLLM key's own model scope still bounds it).
   */
  modelCatalog?: () => Promise<readonly string[] | null>;
  /**
   * P10 Task 2 (P1 Task 8 deferral): structured warning sink for caught
   * WS/event-listener errors. Defaults to the Fastify logger when absent.
   */
  logger?: { warn(obj: unknown, msg?: string): void };
  /**
   * P10 Task 2: server-level live-socket registry. main() creates one and
   * hands it to installShutdownHandlers via closeWs; absent → no tracking
   * (pre-P10 compositions/tests stay source-compatible).
   */
  wsRegistry?: WsSocketRegistry;
  /**
   * P5 Task 15: envelope crypto for MCP/plugin secret sealing
   * (recordIds mcp_servers:{id} / plugins:{id}). main() wires it from
   * OVID_MASTER_KEY. OPTIONAL only so P1-only compositions stay
   * source-compatible; when absent, any route that must seal answers a loud
   * 503 `unavailable` instead of silently dropping secrets.
   */
  crypto?: EnvelopeCrypto;
  /**
   * Optional per-provider connection-health adapter. Production composition
   * deliberately leaves this absent until real typed provider probes exist;
   * the connection health route then reports `unavailable`, never a fake ping.
   */
  connectionHealth?: ConnectionHealthAdapter;
  /** Worker-owned explicit health projection/check/disconnect invocation surface. */
  connectionHealthInvocations?: ConnectionHealthInvocations;
  /**
   * P5 Task 15: the Task-9 server-side OAuth flow (start/callback/disconnect).
   * main() wires createOAuthFlow with its system publisher routed through the
   * SAME `systemHub` field above. OPTIONAL for the same composition-compat
   * reason; absent → the oauth routes answer a loud 503 `unavailable`.
   */
  oauth?: OAuthFlow;
  /**
   * P9 Task 11: BYOK probe seams (fetch + DNS). The composition root never
   * sets these; route tests inject stubs so the provider probe performs no
   * network I/O. OPTIONAL for the same composition-compat reason.
   */
  byok?: ByokRouteOverrides;
  /**
   * Studio repo picker: GitHub REST seam (API base + fetch). The composition
   * root never sets it — production talks to `https://api.github.com`; route
   * tests inject a stub so no network is touched. OPTIONAL for the same
   * composition-compat reason.
   */
  github?: GithubRouteOverrides;
  /**
   * Studio git: the worker's clone/sync/switch service, as a transport seam.
   * The worker owns the session workspace and the credential helper, so the
   * gateway can never run git itself. OPTIONAL: when absent the git routes
   * answer a loud 503 `studio_git_unavailable` and `GET .../git` reports
   * `available: false`, so a client renders no dead control. The composition
   * root wires it once the worker exposes the transport (see COORDINATION.md).
   */
  studioGit?: StudioGitTransport;
  /** Complete opt-in isolated Studio preview API/origin composition. */
  studioPreview?: StudioPreviewGatewayConfig;
  /**
   * P9 Task 16: LEGACY public share routes at the gateway ROOT (POST/GET
   * /shares, /shares/:token, /s/*, /.well-known/assetlinks.json) — Caddy
   * proxies those exact paths here. Absent → the routes are not registered
   * (Python: create is unavailable without OVID_SHARE_BASE_URL). main()
   * wires `{ baseUrl: env.OVID_SHARE_BASE_URL }`.
   */
  shares?: SharesConfig;
  /**
   * P9 Task 16: LEGACY `POST /v1/reports` at the gateway ROOT. main() always
   * wires it; Task 15's lifecycle.access slots into `admission`.
   */
  reports?: ReportsConfig;
  /**
   * P9 Task 15: the account deletion lifecycle. Registered at the gateway
   * ROOT (legacy `/account/*` paths, outside `/cloud/v1`) with its own
   * Firebase verifier so disabled-token recovery never touches the ordinary
   * auth hook. OPTIONAL so existing compositions/tests stay source-compatible;
   * main() wires it when OVID_ACCOUNT_FIREBASE_APP_IDS is configured.
   */
  account?: AccountRouteDeps;
  /**
   * Task 11: composed observability boundary (metric registry, structured
   * log sink, and operational health probes). OPTIONAL so test compositions
   * stay source-compatible; main() always wires the real one.
   */
  observability?: ReturnType<typeof createGatewayObservabilityComposition>;
  /** Root /chat stays unmounted unless the complete opt-in composition exists. */
  collab?: {
    membership: CollabMembership;
    projection: CollabProjection;
    longPoll?: CollabLongPollOptions;
    /** Optional test overrides; production and default composition use canonical stores. */
    objects?: CollabObjectStore;
    reservations?: CollabReservationPort;
    reservedRelease?: CollabReservedRelease;
    orphanSweepMs?: number;
    orphanRescanMs?: number;
    recoveryBatchLimit?: number;
    recoveryDeadlineMs?: number;
    recoveryReservedGroupsPerPass?: number;
    recoveryReservedReleaseLimit?: number;
  };
}

export interface BuildGatewayOptions {
  /** Fastify logger option; defaults to false so inject() tests stay silent. */
  logger?: FastifyServerOptions["logger"];
}

type GatewayLogger = FastifyServerOptions["logger"];
type GatewayLoggerObject = Exclude<GatewayLogger, boolean | undefined>;
type RequestLogInput = FastifyRequest;

const SECRET_REQUEST_LOG_FIELDS = new Set([
  "headers",
  "cookie",
  "authorization",
  "x-ovid-internal-token",
]);

/**
 * Query parameters whose VALUE is a credential. OAuth `code`/`state`, a
 * preview `ticket`, a signed-URL signature and any token/key are bearer
 * material: the request URL reaches the access log, so the value must not.
 */
const SECRET_QUERY_PARAM =
  /^(?:code|state|ticket|token|access_token|refresh_token|id_token|key|api[_-]?key|apikey|secret|client_secret|signature|sig|password|x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|x-goog-credential)$/i;

/**
 * Path shapes whose segment IS the credential: a public share receipt and the
 * per-share invite are unauthenticated bearer links (`/s/<token>`), and the
 * authenticated share management routes carry the same token.
 */
const SECRET_PATH =
  /^(\/(?:s|shares)\/)([^/?#]+)(.*)$/;

/** Keep path/method telemetry while dropping every query on the isolated origin. */
export function sanitizeStudioPreviewRequestLogUrl(rawUrl: string): string {
  if (!isStudioPreviewOriginPath(rawUrl)) return rawUrl;
  const path = rawUrl.split("?", 1)[0]!;
  return rawUrl.includes("?") ? `${path}?[redacted]` : path;
}

/**
 * A query value that is itself a URL or a credential must not be logged, even
 * under an innocuous parameter name.
 */
const CREDENTIAL_VALUE_SHAPE =
  /(?:^|%3A)(?:https?(?::|\/|%3A%2F%2F)|\/\/)|X-Amz-Signature|X-Goog-Signature|Bearer\s|\beyJ|\bgh[pousr]_|\bgithub_pat_|\bsk-/i;

function looksLikeCredentialValue(raw: string): boolean {
  if (raw === "") return false;
  let decoded = raw;
  try {
    decoded = decodeURIComponent(raw);
  } catch {
    // Compare the raw form too; a malformed escape is still not telemetry.
  }
  return CREDENTIAL_VALUE_SHAPE.test(decoded) || CREDENTIAL_VALUE_SHAPE.test(raw);
}

/**
 * The request URL that may reach the access log. The preview origin loses its
 * whole query; every other route keeps its path (safe telemetry) while the
 * value of each credential-bearing query parameter and each share token path
 * segment is replaced with `[redacted]`.
 */
export function sanitizeRequestLogUrl(rawUrl: string): string {
  if (isStudioPreviewOriginPath(rawUrl)) return sanitizeStudioPreviewRequestLogUrl(rawUrl);
  const queryAt = rawUrl.indexOf("?");
  const rawPath = queryAt === -1 ? rawUrl : rawUrl.slice(0, queryAt);
  const query = queryAt === -1 ? "" : rawUrl.slice(queryAt + 1);

  const secretPath = SECRET_PATH.exec(rawPath);
  const path = secretPath === null
    ? rawPath
    : `${secretPath[1]}[redacted]${secretPath[3]}`;

  if (query === "") return path;
  const redacted = query.split("&").map((pair) => {
    const eq = pair.indexOf("=");
    if (eq === -1) return pair;
    const name = pair.slice(0, eq);
    let decoded = name;
    try {
      decoded = decodeURIComponent(name);
    } catch {
      // Malformed percent-encoding still names a parameter; compare raw too.
    }
    return SECRET_QUERY_PARAM.test(decoded) || SECRET_QUERY_PARAM.test(name) ||
      // A parameter whose VALUE is itself an absolute URL or a credential
      // shape is bearer material regardless of its name (`url=`, `target=`).
      looksLikeCredentialValue(decoded) || looksLikeCredentialValue(pair.slice(eq + 1))
      ? `${name}=[redacted]`
      : pair;
  });
  return `${path}?${redacted.join("&")}`;
}

/** Merge rather than replace caller logger/stream/serializer options. */
function studioPreviewLogger(logger: GatewayLogger): GatewayLogger {
  if (logger === undefined || logger === false) return false;
  const options: GatewayLoggerObject = logger === true ? {} : logger;
  const customReq = options.serializers?.req;
  const req = (request: RequestLogInput): Record<string, unknown> => {
    const serialized: Record<string, unknown> = {
      ...(customReq === undefined
        ? {
            method: request.method,
            url: request.url,
            version: request.headers && request.headers["accept-version"],
            host: request.host,
            remoteAddress: request.ip,
            remotePort: request.socket ? request.socket.remotePort : undefined,
          }
        : customReq(request)),
    };
    for (const key of Object.keys(serialized)) {
      if (SECRET_REQUEST_LOG_FIELDS.has(key.toLowerCase())) delete serialized[key];
    }
    if (isStudioPreviewOriginPath(request.url)) {
      serialized.url = sanitizeStudioPreviewRequestLogUrl(request.url);
    } else if (typeof serialized.url === "string") {
      serialized.url = sanitizeRequestLogUrl(serialized.url);
    }
    return serialized;
  };
  return {
    ...options,
    serializers: {
      ...options.serializers,
      req,
    },
  };
}

export const API_PREFIX = "/cloud/v1";

/** The two public health endpoints, with or without the API prefix. */
export function isHealthPath(rawUrl: string): boolean {
  const path = rawUrl.split("?", 1)[0]!.replace(/\/+$/, "");
  return path === "/health" || path === "/health/status" ||
    path === `${API_PREFIX}/health` || path === `${API_PREFIX}/health/status`;
}

/**
 * Capped WS frame size (I2): 256 KiB per frame. The @fastify/websocket (ws)
 * default is 100 MiB per frame — with 32 pre-auth frames bufferable per
 * connection that is a trivial pre-auth OOM vector. 256 KiB is orders above
 * any legitimate client frame (subscribe/ping are < 200 bytes).
 */
export const WS_MAX_PAYLOAD_BYTES = 262_144;

/**
 * Builds the gateway HTTP app: routes under /cloud/v1, everything except
 * /health behind the Task 6 authHook, one ApiError envelope for every
 * failure. Returns an unlistened instance — inject()-testable as-is.
 */
export function buildGateway(
  deps: GatewayDeps,
  opts: BuildGatewayOptions = {},
): FastifyInstance {
  const app = Fastify({
    logger: studioPreviewLogger(opts.logger),
  });

  // Anything that THROWS (route bug, Fastify body-parse rejection) is mapped
  // to the shared envelope here. 4xx keep Fastify's own message (e.g. the
  // JSON parse complaint); 5xx are logged with the real error server-side and
  // collapsed to a generic message for the client.
  app.setErrorHandler((error: FastifyError, request, reply) => {
    const status = typeof error.statusCode === "number" ? error.statusCode : 500;
    if (status < 400 || status >= 500) {
      request.log.error({ err: error }, "unhandled error in route");
      const body: ApiError = {
        error: { code: "internal", message: "Internal server error." },
      };
      return reply.code(500).send(body);
    }
    const body: ApiError = {
      error: {
        code: status === 404 ? "not_found" : "bad_request",
        message: error.message,
      },
    };
    return reply.code(status).send(body);
  });

  // Same envelope for unknown routes (default Fastify 404s would leak a
  // different shape).
  app.setNotFoundHandler((_request, reply) => {
    const body: ApiError = { error: { code: "not_found", message: "Route not found." } };
    return reply.code(404).send(body);
  });

  if (deps.rateLimiter !== undefined) {
    const rateLimitOptions = {
      rateLimiter: deps.rateLimiter,
      verifier: deps.verifier,
      rateLimitInternalSecret: deps.rateLimitInternalSecret,
      trustedProxyCidrs: deps.trustedProxyCidrs,
      clock: deps.clock,
      onDegraded: deps.onRateLimitDegraded,
      // Health stays truthful through a limiter-store outage; it is still
      // rate-limited whenever the store works, so this is not a bypass.
      degradeOnStoreFailure: (request: FastifyRequest) =>
        isHealthPath(request.raw.url ?? request.url),
    };
    if ((deps.rateLimitInternalSecret?.trim() ?? "") !== "") {
      registerRateLimitInternalRoute(app, {
        ...rateLimitOptions,
        rateLimitInternalSecret: deps.rateLimitInternalSecret!,
      });
    }
    const enforceRateLimit = createRateLimitPreHandler(rateLimitOptions);
    app.addHook("preHandler", async (request, reply) => {
      // Dedicated preview requests never enter the Firebase-aware identity
      // path. Their scoped ticket/cookie and live worker registration are the
      // only authorization inputs; API management remains rate-limited.
      if (deps.studioPreview !== undefined && isStudioPreviewOriginPath(request.raw.url ?? request.url)) {
        return;
      }
      return enforceRateLimit(request, reply);
    });
  }

  // Public scope: health + the MCP OAuth callback. Both are explicitly
  // NO-auth: the orchestrator probes health, and the authorization server's
  // browser redirect carries no Ovid credentials — the one-use `state` IS
  // the bearer (validated atomically by the Task-9 flow).
  //
  // The canonical PUBLIC redirect path (OVID_MCP_REDIRECT_URI default
  // `https://ovidsi.com/oauth/callback`) is served at the gateway ROOT so
  // Caddy can proxy that exact path verbatim (no rewrite); the API-prefixed
  // route below stays for direct/internal callers.
  registerMcpOauthPublicCallbackRoute(app, deps);

  // P9 Task 15: legacy account lifecycle paths live at the ROOT (no
  // /cloud/v1 prefix) and carry their own auth — the ordinary hook below
  // never sees them.
  if (deps.account !== undefined) {
    registerAccountRoutes(app, deps.account);
  }

  // The CDN Worker is a service principal, not a Firebase user. Mount its
  // grant check on the root instance, before the authenticated /cloud/v1
  // scope, only with a real >=32-byte credential. A partial configuration is
  // never replaced by a public/grantless v2 route.
  const cdnGrantSecret = (deps.cdn?.grantInternalSecret ?? "").trim();
  if (Buffer.byteLength(cdnGrantSecret, "utf8") >= 32) {
    registerCdnGrantRoutes(app, {
      db: deps.db,
      cdnGrantSecret,
      storage: deps.storage,
      clock: deps.clock,
    });
  }

  // Dedicated preview origin routes are a separate ROOT composition. They
  // never inherit the authenticated /cloud/v1 authHook or forward its cookies.
  if (deps.studioPreview !== undefined) {
    registerStudioPreviewOriginRoot(app, deps.studioPreview);
  }

  app.register(
    async (scope) => {
      registerHealthRoutes(scope, deps);
      registerMcpOauthCallbackRoutes(scope, deps);
    },
    { prefix: API_PREFIX },
  );

  // Authenticated scope: the hook is encapsulated here, so it can never leak
  // onto /health above.
  app.register(
    async (scope) => {
      // onRequest establishes the verified principal before the root rate-limit
      // preHandler; all routes still execute the SAME separate authorization hook.
      scope.addHook("onRequest", authHook(deps.verifier));

      // Single-use WS ticket for Task 8's handshake.
      scope.post("/auth/ticket", async (request) => ({
        ticket: await deps.tickets.mint(request.principal.uid),
      }));

      registerSessionRoutes(scope, deps);
      registerProjectRoutes(scope, deps);
      registerMessageRoutes(scope, deps);
      registerPreferenceRoutes(scope, deps);
      // The model catalog + the account's tier, so a client can offer a real
      // model picker instead of a static "Auto" pill.
      registerModelRoutes(scope, deps);
      // The plan table, so the plan screen describes what the server bills
      // instead of keeping its own copy.
      registerPlanRoutes(scope, deps);
      // The client's entitlement read: the ONLY way a device learns which
      // plan it currently owns. Without this registration the module exists
      // but no request can reach it (404), so Flutter's EntitlementClient
      // can never resolve a tier.
      registerBillingEntitlementRoutes(scope, deps);
      // P2 surfaces. Each module owns its own routes and registers nothing
      // until the capability behind it exists — wired here once so a new
      // module never has to touch this file.
      registerSearchRoutes(scope, deps);
      registerAccountHealthRoutes(scope, deps);
      registerDataControlRoutes(scope, deps);
      registerWebPushRoutes(scope, deps);
      // Wave 4: account settings (push, BYOK routing), custom presets, memory files.
      registerAccountSettingsRoutes(scope, deps);
      registerMemoryRoutes(scope, deps);
      registerEventRoutes(scope, deps);
      registerAttachmentRoutes(scope, deps);
      registerRunRoutes(scope, deps);
      registerImportRoutes(scope, deps);
      registerWorkspaceRoutes(scope, deps);
      registerArtifactRoutes(scope, deps);
      registerArtifactVaultRoutes(scope, deps);
      // W12: signed CDN URL mints (additive; 503 cdn_not_configured without
      // OVID_CDN_* so the client falls back to the canonical presign).
      registerArtifactCdnRoutes(scope, deps);
      // Wave 6 W4: browser Credentials Vault (metadata + sealed secrets).
      registerCredentialRoutes(scope, deps);

      // P5 Task 15: MCP servers/catalog/oauth (authed half), plugins, and the
      // REST system-response path. Each answers a loud 503 when its optional
      // dependency (crypto/oauth/systemHub/plugin queue) is not wired.
      registerMcpServerRoutes(scope, deps);
      registerMcpCatalogRoutes(scope, deps);
      registerMcpOauthRoutes(scope, deps);
      registerPluginRoutes(scope, deps);
      registerSystemResponseRoutes(scope, deps);
      registerSystemRequestRoutes(scope, deps);

      // P4 Task 11: schedule CRUD + runs feed + FCM device registration.
      registerScheduleRoutes(scope, deps);
      registerDevicesRoutes(scope, deps);

      // Wave 3: the run_usage token ledger (caller-scoped).
      registerUsageHistoryRoutes(scope, deps);

      // Studio: list repos/branches, clone, switch branch, sync latest. The
      // git half answers 503 studio_git_unavailable until the worker exposes
      // its transport — an honest refusal, never a fake success.
      registerStudioRoutes(scope, deps);
      if (deps.studioPreview !== undefined) {
        registerStudioPreviewApiRoutes(scope, deps.studioPreview);
      }

      // P9 Task 11: BYOK escrow CRUD + the SSRF-guarded provider probe.
      registerByokRoutes(scope, {
        db: deps.db,
        crypto: deps.crypto,
        ...deps.byok,
      });
    },
    { prefix: API_PREFIX },
  );

  // WS scope: GET /cloud/ws, public by design — no authHook here, the
  // single-use ?ticket= query param IS the auth (verified in the handshake).
  // The websocket plugin must be loaded in the same scope before the route.
  // maxPayload caps every inbound frame BEFORE any handler sees it (I2).
  app.register(async (scope) => {
    await scope.register(websocket, { options: { maxPayload: WS_MAX_PAYLOAD_BYTES } });
    // WsDeps.pty is required at the handler boundary; a gateway composed
    // without a bridge (pre-P2 test compositions) gets the loud fallback
    // below instead of a type hole. main() always wires the real bridge.
    const wsDeps: WsDeps = {
      db: deps.db,
      tickets: deps.tickets,
      events: deps.events,
      pty: deps.pty ?? unavailablePtyBridge(),
      browser: deps.browser,
      approvals: deps.approvals,
      systemHub: deps.systemHub,
      // P4 Task 11/12: the scheduler system bus rides the SAME field REST
      // publishes on, so WS subscribers see every lifecycle event.
      system: deps.system,
      // P10 Task 2: live-socket tracking for the SIGTERM drain, and the
      // structured warning sink for caught WS/listener errors.
      registry: deps.wsRegistry,
      logger: deps.logger ?? app.log,
    };
    registerWsRoute(scope, wsDeps);
  });

  // P9 Task 16: LEGACY public paths registered at the ROOT (outside the
  // /cloud/v1 prefix) so Caddy can proxy them verbatim. Both are no-ops when
  // the composition does not opt in.
  if (deps.shares !== undefined) {
    registerSharesRoutes(app, {
      db: deps.db,
      verifier: deps.verifier,
      ...deps.shares,
    });
  }
  if (deps.reports !== undefined) {
    registerReportsRoutes(app, {
      db: deps.db,
      verifier: deps.verifier,
      ...deps.reports,
    });
  }
  if (deps.collab !== undefined) {
    app.register(async (scope) => {
      registerCollabRoutes(scope, {
        membership: deps.collab!.membership,
        projection: deps.collab!.projection,
        verifier: deps.verifier,
        ...(deps.collab!.longPoll !== undefined ? { longPoll: deps.collab!.longPoll } : {}),
      });
      registerCollabObjectRoutes(scope, {
        membership: deps.collab!.membership,
        objects: deps.collab!.objects ?? createCollabObjectStore(deps.db, { now: deps.clock }),
        reservations: deps.collab!.reservations ?? createCollabReservationPort(
          deps.db,
          undefined,
          { now: deps.clock },
        ),
        ...(deps.collab!.reservedRelease !== undefined
          ? { reservedRelease: deps.collab!.reservedRelease }
          : {}),
        ...(deps.collab!.recoveryReservedGroupsPerPass !== undefined
          ? { recoveryReservedGroupsPerPass: deps.collab!.recoveryReservedGroupsPerPass }
          : {}),
        ...(deps.collab!.recoveryReservedReleaseLimit !== undefined
          ? { recoveryReservedReleaseLimit: deps.collab!.recoveryReservedReleaseLimit }
          : {}),
        storage: deps.storage,
        clock: deps.clock,
        downloadTtlSeconds: deps.presignTtlSeconds,
        ...(deps.collab!.orphanSweepMs !== undefined
          ? { orphanSweepMs: deps.collab!.orphanSweepMs }
          : {}),
        ...(deps.collab!.orphanRescanMs !== undefined
          ? { orphanRescanMs: deps.collab!.orphanRescanMs }
          : {}),
        ...(deps.collab!.recoveryBatchLimit !== undefined
          ? { recoveryBatchLimit: deps.collab!.recoveryBatchLimit }
          : {}),
        ...(deps.collab!.recoveryDeadlineMs !== undefined
          ? { recoveryDeadlineMs: deps.collab!.recoveryDeadlineMs }
          : {}),
      });
    });
  }

  return app;
}

/** Default graceful-drain budget before a forced exit. */
export const DEFAULT_SHUTDOWN_DRAIN_MS = 10_000;
/** Close code sent to live WS sockets on a restart drain (RFC 6455 going away). */
export const WS_RESTART_CLOSE_CODE = 1001;
/** Human-readable close reason the thin client observes on a restart. */
export const WS_RESTART_CLOSE_REASON = "server restarting";

export interface ShutdownHandlerOptions {
  /** Hard-exit deadline measured from the signal. Default 10000 ms. */
  drainMs?: number;
  /**
   * Closes every live WS socket with the restart code/reason. main() passes
   * `createWsSocketRegistry().closeAll`; the return value is awaited so close
   * frames flush before `app.close()` tears the server down.
   */
  closeWs?: (code: number, reason: string) => void | Promise<void>;
  /** Test seam: process exit (default `process.exit`). */
  exit?: (code: number) => void;
}

/**
 * P10 Task 2: gateway SIGTERM/SIGINT drain.
 *
 * On the first signal: close every live WS socket with code 1001 reason
 * "server restarting" (so reconnecting clients know a restart, not a
 * failure), stop accepting / drain the Fastify server via `app.close()`, then
 * exit 0. A `drainMs` hard-exit timer guarantees the process never outlives
 * the orchestrator's stop grace period. Repeated signals are idempotent.
 *
 * Returns the shutdown function (awaitable in tests); installed by main().
 */
export function installShutdownHandlers(
  app: FastifyInstance,
  opts: ShutdownHandlerOptions = {},
): () => Promise<void> {
  const drainMs = opts.drainMs ?? DEFAULT_SHUTDOWN_DRAIN_MS;
  const exit = opts.exit ?? ((code: number) => process.exit(code));
  let inFlight: Promise<void> | null = null;

  const shutdown = (): Promise<void> => {
    if (inFlight !== null) return inFlight;
    inFlight = (async () => {
      // Armed FIRST: even a wedged close path cannot outlive the budget.
      const hardExit = setTimeout(() => exit(1), drainMs);
      hardExit.unref?.();
      try {
        await opts.closeWs?.(WS_RESTART_CLOSE_CODE, WS_RESTART_CLOSE_REASON);
      } catch (err) {
        app.log.warn({ err }, "shutdown: closing ws sockets failed");
      }
      try {
        await app.close();
      } catch (err) {
        app.log.warn({ err }, "shutdown: app.close failed");
      } finally {
        clearTimeout(hardExit);
      }
      exit(0);
    })();
    return inFlight;
  };

  const onSignal = (): void => {
    void shutdown();
  };
  process.once("SIGTERM", onSignal);
  process.once("SIGINT", onSignal);
  return shutdown;
}

/** Never-wired bridge fallback: every pty frame fails loudly with `internal`. */
function unavailablePtyBridge(): PtyBridge {
  let warned = false;
  // C1 caveat (review round-1 Minor 2): loud SERVER-side too — one log line
  // per composition (not per frame), so an operator composing a gateway
  // without a bridge learns it from the log, not from client reports.
  const warnOnce = (): void => {
    if (warned) return;
    warned = true;
    console.warn(
      "[gateway] WS terminal op refused: no PtyBridge configured (GatewayDeps.pty missing)",
    );
  };
  const reject = (): Promise<never> => {
    warnOnce();
    return Promise.reject(new PtyBridgeError("internal", "Terminal bridge not configured."));
  };
  return {
    open: reject,
    attach: reject,
    send: async () => {
      warnOnce();
    },
    lookup: async () => {
      warnOnce();
      return null;
    },
  };
}
