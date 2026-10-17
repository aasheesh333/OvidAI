/**
 * Mint app environment — Node port of server/mint/mint.py's config block
 * (plus the billing + images config those later tasks consume). Every default
 * is copied from the Python sources: this app must be droppable into the live
 * stack's env unchanged.
 *
 * Redis note: `redisDb2Url`'s URL itself carries the db selector (prod …/2,
 * tests …/9) — exactly like the Python REDIS_URL. The loader never parses or
 * rewrites the URL.
 */

export interface MintEnv {
  nodeEnv: string;
  host: string;
  publicPort: number; // default 8091
  adminPort: number; // default 8092
  databaseUrl: string;
  redisDb2Url: string;
  litellmBaseUrl: string;
  litellmMasterKey: string;
  adminMasterKey: string; // OVID_ADMIN_MASTER_KEY (console)
  internalApiSecret: string; // OVID_INTERNAL_API_SECRET (Task 9)
  firebaseProjectId: string;
  appcheckEnabled: boolean;
  /** Allowed Firebase app ids per platform: OVID_APPCHECK_APPS "android:<id>,web:<id>". */
  appcheckApps: Record<string, "android" | "web">;
  allowTestUpgrade: boolean;
  publicBaseUrl: string; // default "https://cloud.dhanuksoftwares.com/v1"
  alertTelegramBotToken: string;
  alertTelegramChatId: string;
  alertWebhookUrl: string;
  dailySpendAlertUsd: number;
  mintStateDir: string;
  reapplySyncMax: number;
  auditMax: number;
  usageCacheS: number;
  sweepS: number;
  webTeamDailyUsd: number;
  /** Anti-abuse ceilings — defaults 40/3600/12/600/86400/20/3600/500/3600 exactly as mint.py. */
  abuse: {
    mintCallsPerIp: number;
    mintWindowS: number;
    newAccountsPerIpPerWindow: number;
    signupVelocityWindowS: number;
    ipAccountWindowS: number;
    abuseStrikeLimit: number;
    abuseWindowS: number;
    globalNewkeysPerWindow: number;
    newkeyWindowS: number;
  };
  /** Google Play billing config (server/billing/api.py env names). */
  play: {
    serviceAccountFile: string | null;
    packageName: string;
    products: Record<string, string> | null;
    rtdnAudience: string | null;
    rtdnServiceAccount: string | null;
    rtdnSharedSecret: string | null;
    requireAccountId: boolean;
  };
  /** Images gateway config (deploy/images_gateway.py env names). */
  images: {
    maxUpstreamCostUsd: string | null;
    inferhubApiKey: string | null;
    directEditHosts: string;
    editCostUsd: string | null;
    probeKey: string | null;
    probeMaxUsd: number;
    probeDailyUsd: number;
    probeTtlS: number;
    probeStaggerS: number;
    probeMaxSizes: number;
  };
}

const DEFAULT_HOST = "127.0.0.1"; // container deploys override with HOST=0.0.0.0
const DEFAULT_PUBLIC_PORT = 8091;
const DEFAULT_ADMIN_PORT = 8092;

// ── parsing helpers — every throw names the offending variable ──

function requiredString(raw: NodeJS.ProcessEnv, name: string): string {
  const value = raw[name]?.trim() ?? "";
  if (value === "") {
    throw new Error(`${name} is required`);
  }
  return value;
}

function optionalString(raw: NodeJS.ProcessEnv, name: string, fallback: string): string {
  const value = raw[name]?.trim() ?? "";
  return value === "" ? fallback : value;
}

/** Unset/empty → null (distinct from a fallback: "not configured"). */
function optionalStringOrNull(raw: NodeJS.ProcessEnv, name: string): string | null {
  const value = raw[name]?.trim() ?? "";
  return value === "" ? null : value;
}

function intVar(raw: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const value = raw[name]?.trim() ?? "";
  if (value === "") {
    return fallback;
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed)) {
    throw new Error(`${name} must be an integer, got: ${value}`);
  }
  return parsed;
}

function positiveIntVar(raw: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const parsed = intVar(raw, name, fallback);
  const provided = (raw[name] ?? "").trim() !== "";
  if (provided && parsed < 1) {
    throw new Error(`${name} must be a positive integer, got: ${parsed}`);
  }
  return parsed;
}

function floatVar(raw: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const value = raw[name]?.trim() ?? "";
  if (value === "") {
    return fallback;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`${name} must be a finite number, got: ${value}`);
  }
  return parsed;
}

function boolVar(raw: NodeJS.ProcessEnv, name: string, fallback: boolean): boolean {
  const value = raw[name]?.trim().toLowerCase() ?? "";
  if (value === "") {
    return fallback;
  }
  if (value === "true" || value === "1") return true;
  if (value === "false" || value === "0") return false;
  throw new Error(`${name} must be "true" or "false", got: ${raw[name]}`);
}

function portVar(raw: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const port = positiveIntVar(raw, name, fallback);
  if (port > 65535) {
    throw new Error(`${name} must be an integer between 1 and 65535, got: ${port}`);
  }
  return port;
}

/**
 * OVID_APPCHECK_APPS "android:<appId>,web:<appId>" → {appId: platform}.
 * mint.py parity: split on the FIRST colon so Firebase app ids (which contain
 * colons — "1:234:android:abc") survive intact.
 */
function parseAppcheckApps(raw: NodeJS.ProcessEnv): Record<string, "android" | "web"> {
  const out: Record<string, "android" | "web"> = {};
  const value = raw.OVID_APPCHECK_APPS ?? "";
  for (const entry of value.split(",")) {
    const trimmed = entry.trim();
    if (trimmed === "") continue;
    const colon = trimmed.indexOf(":");
    if (colon <= 0) {
      throw new Error(`OVID_APPCHECK_APPS entry must be "<platform>:<appId>", got: ${trimmed}`);
    }
    const platform = trimmed.slice(0, colon).trim().toLowerCase();
    const appId = trimmed.slice(colon + 1).trim();
    if (platform !== "android" && platform !== "web") {
      throw new Error(`OVID_APPCHECK_APPS platform must be "android" or "web", got: ${platform}`);
    }
    if (appId === "") {
      throw new Error(`OVID_APPCHECK_APPS entry has an empty app id: ${trimmed}`);
    }
    out[appId] = platform;
  }
  return out;
}

/**
 * OVID_PLAY_PRODUCTS: JSON object mapping Play product id → tier id. Unset →
 * null (Task 10's loadProducts applies the Python DEFAULT_PRODUCTS then).
 */
function parsePlayProducts(raw: NodeJS.ProcessEnv): Record<string, string> | null {
  const value = raw.OVID_PLAY_PRODUCTS?.trim() ?? "";
  if (value === "") {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error(`OVID_PLAY_PRODUCTS must be a JSON object, got: ${value}`);
  }
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    Array.isArray(parsed) ||
    Object.keys(parsed).length === 0
  ) {
    throw new Error("OVID_PLAY_PRODUCTS must be a non-empty JSON object of product→tier");
  }
  for (const [product, tier] of Object.entries(parsed as Record<string, unknown>)) {
    if (typeof tier !== "string") {
      throw new Error(`OVID_PLAY_PRODUCTS mapping ${product} must map to a tier string`);
    }
  }
  return parsed as Record<string, string>;
}

/**
 * Validate + default the mint environment. Throws naming the offending
 * variable on anything invalid; refuses ALLOW_TEST_UPGRADE when
 * NODE_ENV=production (the /upgrade test hatch must never exist in prod).
 */
export function loadMintEnv(raw: NodeJS.ProcessEnv): MintEnv {
  const nodeEnv = raw.NODE_ENV?.trim() || "development";

  const host = optionalString(raw, "HOST", DEFAULT_HOST);
  const publicPort = portVar(raw, "PUBLIC_PORT", DEFAULT_PUBLIC_PORT);
  const adminPort = portVar(raw, "ADMIN_PORT", DEFAULT_ADMIN_PORT);

  const databaseUrl = requiredString(raw, "DATABASE_URL");
  const redisDb2Url = optionalString(raw, "REDIS_DB2_URL", "redis://redis:6379/2");

  const litellmBaseUrl = optionalString(raw, "LITELLM_BASE", "http://litellm:4000");
  const litellmMasterKey = requiredString(raw, "LITELLM_MASTER_KEY");
  const adminMasterKey = requiredString(raw, "OVID_ADMIN_MASTER_KEY");
  const internalApiSecret = requiredString(raw, "OVID_INTERNAL_API_SECRET");

  const firebaseProjectId = requiredString(raw, "FIREBASE_PROJECT_ID");
  const appcheckEnabled = boolVar(raw, "APPCHECK_ENABLED", true);
  const appcheckApps = parseAppcheckApps(raw);

  const allowTestUpgrade = boolVar(raw, "ALLOW_TEST_UPGRADE", false);
  if (allowTestUpgrade && nodeEnv === "production") {
    throw new Error("ALLOW_TEST_UPGRADE is forbidden when NODE_ENV=production");
  }

  const publicBaseUrl = optionalString(
    raw,
    "PUBLIC_BASE_URL",
    "https://cloud.dhanuksoftwares.com/v1",
  );

  return {
    nodeEnv,
    host,
    publicPort,
    adminPort,
    databaseUrl,
    redisDb2Url,
    litellmBaseUrl,
    litellmMasterKey,
    adminMasterKey,
    internalApiSecret,
    firebaseProjectId,
    appcheckEnabled,
    appcheckApps,
    allowTestUpgrade,
    publicBaseUrl,
    alertTelegramBotToken: optionalString(raw, "ALERT_TELEGRAM_BOT_TOKEN", ""),
    alertTelegramChatId: optionalString(raw, "ALERT_TELEGRAM_CHAT_ID", ""),
    alertWebhookUrl: optionalString(raw, "ALERT_WEBHOOK_URL", ""),
    dailySpendAlertUsd: floatVar(raw, "DAILY_SPEND_ALERT_USD", 20),
    mintStateDir: optionalString(raw, "MINT_STATE_DIR", "/data"),
    reapplySyncMax: positiveIntVar(raw, "REAPPLY_SYNC_MAX", 200),
    auditMax: positiveIntVar(raw, "AUDIT_MAX", 5000),
    usageCacheS: positiveIntVar(raw, "USAGE_CACHE_S", 15),
    sweepS: positiveIntVar(raw, "MINT_SWEEP_S", 30),
    webTeamDailyUsd: floatVar(raw, "WEB_TEAM_DAILY_USD", 25),
    abuse: {
      mintCallsPerIp: positiveIntVar(raw, "MINT_CALLS_PER_IP", 40),
      mintWindowS: positiveIntVar(raw, "MINT_WINDOW_S", 3600),
      newAccountsPerIpPerWindow: positiveIntVar(
        raw,
        "NEW_ACCOUNTS_PER_IP_PER_WINDOW",
        12,
      ),
      signupVelocityWindowS: positiveIntVar(raw, "SIGNUP_VELOCITY_WINDOW_S", 600),
      ipAccountWindowS: positiveIntVar(raw, "IP_ACCOUNT_WINDOW_S", 24 * 3600),
      abuseStrikeLimit: positiveIntVar(raw, "ABUSE_STRIKE_LIMIT", 20),
      abuseWindowS: positiveIntVar(raw, "ABUSE_WINDOW_S", 3600),
      globalNewkeysPerWindow: positiveIntVar(raw, "GLOBAL_NEWKEYS_PER_WINDOW", 500),
      newkeyWindowS: positiveIntVar(raw, "NEWKEY_WINDOW_S", 3600),
    },
    play: {
      serviceAccountFile: optionalStringOrNull(raw, "OVID_PLAY_SERVICE_ACCOUNT_FILE"),
      packageName: optionalString(raw, "OVID_PLAY_PACKAGE", "com.dhanuk.ovidai"),
      products: parsePlayProducts(raw),
      rtdnAudience: optionalStringOrNull(raw, "OVID_RTDN_AUDIENCE"),
      rtdnServiceAccount: optionalStringOrNull(raw, "OVID_RTDN_SERVICE_ACCOUNT"),
      rtdnSharedSecret: optionalStringOrNull(raw, "OVID_RTDN_SHARED_SECRET"),
      requireAccountId: boolVar(raw, "OVID_BILLING_REQUIRE_ACCOUNT_ID", true),
    },
    images: {
      maxUpstreamCostUsd: optionalStringOrNull(raw, "OVID_IMAGE_MAX_UPSTREAM_USD"),
      inferhubApiKey: optionalStringOrNull(raw, "INFERHUB_API_KEY"),
      directEditHosts: optionalString(raw, "OVID_IMAGE_DIRECT_EDIT_HOSTS", "api.inferhub.dev"),
      editCostUsd: optionalStringOrNull(raw, "OVID_IMAGE_EDIT_COST_USD"),
      probeKey: optionalStringOrNull(raw, "OVID_PROBE_KEY"),
      probeMaxUsd: floatVar(raw, "OVID_PROBE_MAX_USD", 0.5),
      probeDailyUsd: floatVar(raw, "OVID_PROBE_DAILY_USD", 5.0),
      probeTtlS: floatVar(raw, "OVID_PROBE_TTL_SECONDS", 7 * 24 * 3600),
      probeStaggerS: floatVar(raw, "OVID_PROBE_STAGGER_SECONDS", 30),
      probeMaxSizes: positiveIntVar(raw, "OVID_PROBE_MAX_SIZES", 4),
    },
  };
}
