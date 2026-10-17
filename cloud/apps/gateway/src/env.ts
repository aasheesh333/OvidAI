export interface GatewayEnv {
  nodeEnv: string;
  port: number;
  host: string;
  authMode: "firebase" | "test";
  databaseUrl: string;
  redisQUrl: string;
  redisMintUrl: string;
  mintBaseUrl: string;
  /**
   * P7 Task 12: the worker file service's container-internal base URL
   * (e.g. `http://127.0.0.1:8091`). Required in firebase mode; test mode
   * defaults to "" (dev/test compositions inject a stub WorkerClient).
   */
  workerInternalUrl: string;
  /** Shared container secret the file service checks on every request. */
  internalToken: string;
  /** OVID_FILE_INLINE_MAX_BYTES — mirrors the worker's inline cap (default 1 MiB). */
  fileInlineMaxBytes: number;
  /** OVID_PUT_MAX_BYTES — decoded-body cap for PUT /workspace/file (default 8 MiB). */
  putMaxBytes: number;
  /** OVID_PRESIGN_TTL_SECONDS — clamped into 60..86400 (default 3600). */
  presignTtlSeconds: number;
  /** OVID_HYDRATE_WAIT_MS — how long PUT waits for a cold workspace to warm (default 20 s). */
  hydrateWaitMs: number;
  /** REDIS_C_URL — cache-class redis (activity keys); falls back to redisQUrl. */
  redisCUrl: string;
  /**
   * P5 Task 15: AES-256 master key (64 hex chars) for MCP/plugin envelope
   * sealing. REQUIRED when authMode is `firebase`; in `test` mode an empty
   * value is allowed (a composition that exercises the sealing routes injects
   * a fixed key directly instead).
   */
  masterKey: string;
  /**
   * P5 Task 15: the MCP OAuth redirect URI registered with authorization
   * servers (default `https://ovidsi.com/oauth/callback`). The gateway serves
   * this exact public path at its ROOT (`registerMcpOauthPublicCallbackRoute`);
   * the Caddy snippet proxies it verbatim — no rewrite.
   */
  mcpRedirectUri: string;
}

const DEFAULT_PORT = 8081;
const DEFAULT_HOST = "127.0.0.1";

const DEFAULT_FILE_INLINE_MAX_BYTES = 1_048_576;
const DEFAULT_PUT_MAX_BYTES = 8_388_608;
const DEFAULT_PRESIGN_TTL_SECONDS = 3600;
const PRESIGN_TTL_MIN_SECONDS = 60;
const PRESIGN_TTL_MAX_SECONDS = 86_400;
const DEFAULT_HYDRATE_WAIT_MS = 20_000;
export const DEFAULT_MCP_REDIRECT_URI = "https://ovidsi.com/oauth/callback";
const MASTER_KEY_HEX_RE = /^[0-9a-fA-F]{64}$/;

/**
 * Validate + default the gateway's environment.
 *
 * - `authMode` defaults to `firebase`; `test` mode is a dev/test bypass and is
 *   refused outright when `nodeEnv` is `production` (plan's global constraint:
 *   the gateway must refuse to start with test auth in production).
 * - Every URL is required (non-empty) in firebase mode; in test mode missing
 *   URLs default to "" so a bare `OVID_AUTH_MODE=test` boots for local tests.
 * - Throws with the offending variable name on anything invalid.
 */
export function loadGatewayEnv(raw: NodeJS.ProcessEnv): GatewayEnv {
  const nodeEnv = raw.NODE_ENV?.trim() || "development";

  let port = DEFAULT_PORT;
  const portRaw = raw.PORT;
  // If PORT is set at all it must be a valid integer port — an empty or
  // malformed value is a deployment misconfiguration and must fail loudly.
  if (portRaw !== undefined) {
    const parsed = Number(portRaw.trim());
    if (portRaw.trim() === "" || !Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
      throw new Error(`PORT must be an integer between 1 and 65535, got: ${portRaw}`);
    }
    port = parsed;
  }

  const authModeRaw = raw.OVID_AUTH_MODE?.trim() || "firebase";
  if (authModeRaw !== "firebase" && authModeRaw !== "test") {
    throw new Error(`OVID_AUTH_MODE must be "firebase" or "test", got: ${authModeRaw}`);
  }
  const authMode: GatewayEnv["authMode"] = authModeRaw;

  // HOST defaults to loopback (bare-metal/dev: closed by default). The
  // container deploy MUST set HOST=0.0.0.0 — docker-proxy forwards a
  // published port to the container's bridge IP, so a loopback-bound
  // listener is unreachable from the host's reverse proxy.
  let host = DEFAULT_HOST;
  if (raw.HOST !== undefined) {
    host = raw.HOST.trim();
    if (host === "") {
      throw new Error("HOST must be a non-empty bind address when set");
    }
  }

  if (nodeEnv === "production" && authMode === "test") {
    throw new Error("OVID_AUTH_MODE=test is forbidden when NODE_ENV=production");
  }

  const requiredUrl = (name: keyof NodeJS.ProcessEnv): string => {
    const value = raw[name]?.trim() ?? "";
    if (authMode === "firebase" && value === "") {
      throw new Error(`${name} is required when OVID_AUTH_MODE=firebase`);
    }
    return value;
  };

  // P7 Task 12 knobs. Byte/wait values must be positive integers when set —
  // anything else is a deployment misconfiguration and fails loudly. The
  // presign TTL CLAMPS (never a 400 at boot for an aggressive operator
  // value); a missing REDIS_C_URL is a documented dev fallback, not an error.
  const positiveInt = (name: string, fallback: number): number => {
    const text = raw[name]?.trim();
    if (text === undefined || text === "") return fallback;
    const n = Number(text);
    if (!Number.isInteger(n) || n < 1) {
      throw new Error(`${name} must be a positive integer, got: ${text}`);
    }
    return n;
  };

  const fileInlineMaxBytes = positiveInt("OVID_FILE_INLINE_MAX_BYTES", DEFAULT_FILE_INLINE_MAX_BYTES);
  const putMaxBytes = positiveInt("OVID_PUT_MAX_BYTES", DEFAULT_PUT_MAX_BYTES);
  const hydrateWaitMs = positiveInt("OVID_HYDRATE_WAIT_MS", DEFAULT_HYDRATE_WAIT_MS);

  let presignTtlSeconds = positiveInt("OVID_PRESIGN_TTL_SECONDS", DEFAULT_PRESIGN_TTL_SECONDS);
  presignTtlSeconds = Math.min(
    PRESIGN_TTL_MAX_SECONDS,
    Math.max(PRESIGN_TTL_MIN_SECONDS, presignTtlSeconds),
  );

  // REDIS_C_URL is optional: activity keys share the queue redis in dev
  // (same fallback the worker documents with a boot-time warning).
  const redisCUrl = raw.REDIS_C_URL?.trim() || (raw.REDIS_Q_URL?.trim() ?? "");

  // The internal token is required (non-empty) in firebase mode; it is
  // INVOKED from the return object so the required-var evaluation order
  // stays pinned (DATABASE_URL…MINT_BASE_URL, then the worker URL, then the
  // token — a missing var surfaces distinctly, never masked).
  const requiredInternalToken = (): string => {
    const value = raw.OVID_INTERNAL_TOKEN?.trim() ?? "";
    if (authMode === "firebase" && value === "") {
      throw new Error("OVID_INTERNAL_TOKEN is required when OVID_AUTH_MODE=firebase");
    }
    return value;
  };

  // P5 Task 15: the envelope master key. Required in firebase mode (MCP
  // secret sealing and plugin config sealing both refuse to operate without
  // it); test mode may leave it empty. A present value must be exactly 64
  // hex chars — a malformed key fails at boot, never half-works. INVOKED from
  // the return object so the required-var evaluation order stays pinned
  // (DATABASE_URL…MINT_BASE_URL, worker URL, internal token, then master key).
  const requiredMasterKey = (): string => {
    const value = raw.OVID_MASTER_KEY?.trim() ?? "";
    if (value === "" && authMode === "firebase") {
      throw new Error("OVID_MASTER_KEY is required when OVID_AUTH_MODE=firebase");
    }
    if (value !== "" && !MASTER_KEY_HEX_RE.test(value)) {
      throw new Error("OVID_MASTER_KEY must be exactly 64 hex characters (32 bytes)");
    }
    return value;
  };

  // The callback is always a public https route; a malformed value is a
  // deployment misconfiguration (the authorization server would reject it
  // later anyway, but boot-time is where it is cheap to catch).
  const mcpRedirectUri = raw.OVID_MCP_REDIRECT_URI?.trim() || DEFAULT_MCP_REDIRECT_URI;
  try {
    const u = new URL(mcpRedirectUri);
    if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("bad scheme");
  } catch {
    throw new Error("OVID_MCP_REDIRECT_URI must be an absolute http(s) URL");
  }

  return {
    nodeEnv,
    port,
    host,
    authMode,
    databaseUrl: requiredUrl("DATABASE_URL"),
    redisQUrl: requiredUrl("REDIS_Q_URL"),
    redisMintUrl: requiredUrl("REDIS_MINT_URL"),
    mintBaseUrl: requiredUrl("MINT_BASE_URL"),
    workerInternalUrl: requiredUrl("OVID_WORKER_INTERNAL_URL"),
    internalToken: requiredInternalToken(),
    fileInlineMaxBytes,
    putMaxBytes,
    presignTtlSeconds,
    hydrateWaitMs,
    redisCUrl,
    masterKey: requiredMasterKey(),
    mcpRedirectUri,
  };
}
