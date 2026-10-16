export interface GatewayEnv {
  nodeEnv: string;
  port: number;
  host: string;
  authMode: "firebase" | "test";
  databaseUrl: string;
  redisQUrl: string;
  redisMintUrl: string;
  mintBaseUrl: string;
}

const DEFAULT_PORT = 8081;
const DEFAULT_HOST = "127.0.0.1";

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

  return {
    nodeEnv,
    port,
    host,
    authMode,
    databaseUrl: requiredUrl("DATABASE_URL"),
    redisQUrl: requiredUrl("REDIS_Q_URL"),
    redisMintUrl: requiredUrl("REDIS_MINT_URL"),
    mintBaseUrl: requiredUrl("MINT_BASE_URL"),
  };
}
