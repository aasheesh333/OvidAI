/**
 * Browser engine admission/config knobs — all env-tunable, defaults pinned
 * to the research §3 admission numbers. Malformed values throw naming the
 * variable (fail-fast at worker boot, never at request time).
 */

export interface ScreencastConfig {
  width: number;
  height: number;
  quality: number;
  everyNthFrame: number;
  maxFramesInFlight: number;
}

export interface BrowserEngineConfig {
  /** MAX_LIVE_BROWSERS, default 4 */
  maxLiveBrowsers: number;
  /** MAX_TIER1_FALLBACK_CONTEXTS, default 2 */
  tier1FallbackContexts: number;
  /** BROWSER_IDLE_EVICT_MS, default 180_000 */
  idleEvictMs: number;
  /** MAX_TIER1_PROCESSES, default 8 */
  maxTier1Processes: number;
  /** TIER1_TIMEOUT_MS, default 20_000 */
  tier1TimeoutMs: number;
  /** MAX_ACTIVE_SCREENCASTS, default 3 */
  maxActiveScreencasts: number;
  /** OVID_SCREENCAST_LOAD_MAX, default 6.0 (os.loadavg()[0] step-down threshold on 8c) */
  screencastLoadMax: number;
  screencast: ScreencastConfig;
  /** OVID_BROWSER_STATE_DIR (null ⇒ no persistence) */
  stateDir: string | null;
  /** OVID_LIGHTPANDA_BIN (null ⇒ tier-1 skips Lightpanda steps) */
  lightpandaBin: string | null;
  /** OVID_BROWSER_ALLOW_HOSTS, comma-split, default [] (tests: ["127.0.0.1","localhost"]) */
  allowHosts: string[];
  /** OVID_PUBLIC_IP (SSRF self-block; P2 nftables uses the same value) */
  ownPublicIp: string | null;
  chromiumArgs: string[];
}

function positiveInt(env: NodeJS.ProcessEnv, name: string): number | undefined {
  const raw = env[name];
  if (raw === undefined || raw === "") return undefined;
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`${name} must be a positive integer (got "${raw}")`);
  }
  return n;
}

function positiveNumber(env: NodeJS.ProcessEnv, name: string): number | undefined {
  const raw = env[name];
  if (raw === undefined || raw === "") return undefined;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) {
    throw new Error(`${name} must be a positive number (got "${raw}")`);
  }
  return n;
}

function optionalString(env: NodeJS.ProcessEnv, name: string): string | null {
  const raw = env[name];
  if (raw === undefined || raw === "") return null;
  return raw;
}

export function loadBrowserEngineConfig(raw: NodeJS.ProcessEnv): BrowserEngineConfig {
  return {
    maxLiveBrowsers: positiveInt(raw, "MAX_LIVE_BROWSERS") ?? 4,
    tier1FallbackContexts: positiveInt(raw, "MAX_TIER1_FALLBACK_CONTEXTS") ?? 2,
    idleEvictMs: positiveInt(raw, "BROWSER_IDLE_EVICT_MS") ?? 180_000,
    maxTier1Processes: positiveInt(raw, "MAX_TIER1_PROCESSES") ?? 8,
    tier1TimeoutMs: positiveInt(raw, "TIER1_TIMEOUT_MS") ?? 20_000,
    maxActiveScreencasts: positiveInt(raw, "MAX_ACTIVE_SCREENCASTS") ?? 3,
    screencastLoadMax: positiveNumber(raw, "OVID_SCREENCAST_LOAD_MAX") ?? 6.0,
    screencast: {
      width: positiveInt(raw, "OVID_SCREENCAST_WIDTH") ?? 1280,
      height: positiveInt(raw, "OVID_SCREENCAST_HEIGHT") ?? 800,
      quality: positiveInt(raw, "OVID_SCREENCAST_QUALITY") ?? 60,
      everyNthFrame: positiveInt(raw, "OVID_SCREENCAST_EVERY_NTH_FRAME") ?? 2,
      maxFramesInFlight: positiveInt(raw, "OVID_SCREENCAST_MAX_FRAMES_IN_FLIGHT") ?? 2,
    },
    stateDir: optionalString(raw, "OVID_BROWSER_STATE_DIR"),
    lightpandaBin: optionalString(raw, "OVID_LIGHTPANDA_BIN"),
    allowHosts: (raw.OVID_BROWSER_ALLOW_HOSTS ?? "")
      .split(",")
      .map((h) => h.trim())
      .filter((h) => h !== ""),
    ownPublicIp: optionalString(raw, "OVID_PUBLIC_IP"),
    chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
  };
}
