/**
 * Browser engine admission/config knobs — all env-tunable, defaults pinned
 * to the research §3 admission numbers. Malformed values throw naming the
 * variable (fail-fast at worker boot, never at request time).
 */

import { clampScreencastFps } from "./screencast.js";

export interface ScreencastConfig {
  width: number;
  height: number;
  quality: number;
  everyNthFrame: number;
  maxFramesInFlight: number;
  /**
   * Wave 5 R3: the live view's frame-rate cap (OVID_SCREENCAST_MAX_FPS,
   * default 4 ⇒ 3–5 fps effective). Frames arriving early are held UNACKED
   * until their slot, so chromium itself is paced. Absent ⇒ uncapped.
   */
  maxFps?: number;
}

export interface BrowserEngineConfig {
  /** MAX_LIVE_BROWSERS, default 4 */
  maxLiveBrowsers: number;
  /**
   * Product spec §8: 45 s with no human input while a viewer is attached puts
   * the page headless (frames stop, the session/context stays alive).
   * OVID_WATCH_IDLE_HEADLESS_MS; 0 disables the conversion (tests/tight boxes).
   * Optional so older configs keep compiling; the engine defaults to 45 s.
   */
  watchIdleHeadlessMs?: number;
  /** MAX_TIER1_FALLBACK_CONTEXTS, default 2 */
  tier1FallbackContexts: number;
  /**
   * BROWSER_IDLE_EVICT_MS — how long a live context may sit untouched before
   * the pool freezes it (storageState flushed, context closed). Default
   * 15_000: Muse-style ephemeral step leases, so a context exists only while
   * a step or a manual takeover is running. The engine re-navigates to the
   * session's last URL on the next step, so eviction is transparent.
   */
  idleEvictMs: number;
  /** MAX_TIER1_PROCESSES, default 8 */
  maxTier1Processes: number;
  /** TIER1_TIMEOUT_MS, default 20_000 */
  tier1TimeoutMs: number;
  /** MAX_ACTIVE_SCREENCASTS, default 3 */
  maxActiveScreencasts: number;
  /** OVID_SCREENCAST_LOAD_MAX, default 6.0 (os.loadavg()[0] step-down threshold on 8c) */
  screencastLoadMax: number;
  /**
   * Wave 6 W4: how long the screencast keeps rendering after the last viewer
   * leaves before the browser goes headless (frames stop, context stays
   * alive). Default 45_000; 0 disables the grace (tests / tight boxes).
   * OVID_SCREENCAST_DETACH_GRACE_MS.
   */
  screencastDetachGraceMs: number;
  screencast: ScreencastConfig;
  /** OVID_BROWSER_STATE_DIR (null ⇒ no persistence) */
  stateDir: string | null;
  /** OVID_LIGHTPANDA_BIN (null ⇒ tier-1 skips Lightpanda steps) */
  lightpandaBin: string | null;
  /** OVID_BROWSER_ALLOW_HOSTS, comma-split, default [] (tests: ["127.0.0.1","localhost"]) */
  allowHosts: string[];
  /** OVID_PUBLIC_IP (SSRF self-block; P2 nftables uses the same value) */
  ownPublicIp: string | null;
  /**
   * Abort media/font requests and known ad/tracker hosts at the context
   * layer (OVID_BROWSER_BLOCK_HEAVY_RESOURCES=0 disables). Cuts per-context
   * memory and CPU enough to run many more live contexts on the same box.
   */
  blockHeavyResources: boolean;
  chromiumArgs: string[];
  /**
   * OVID_BROWSER_EGRESS_UID — the dedicated uid every browser process
   * (Chromium + Lightpanda) runs as. For a range ("230000-230099") the FIRST
   * uid is used; the whole range is validated so the rendered nftables rule
   * and the running processes agree. null ⇒ no uid drop (non-production
   * dev/test default; production refuses it).
   */
  egressUid?: number | null;
  /** The configured browser uid range, or null when OVID_BROWSER_EGRESS_UID is unset. */
  browserUidRange?: [number, number] | null;
  /**
   * The sandbox jail uid block [base, max] parsed from OVID_SANDBOX_UID_BASE /
   * OVID_SANDBOX_UID_MAX. The browser uid must live in a DISTINCT keyspace —
   * a browser nftables rule that overlapped this block could shadow a jail.
   */
  sandboxUidRange?: [number, number];
  /** OVID_BROWSER_UID_DROP: "auto" (default) | "required" | "disabled". */
  uidDropMode?: UidDropMode;
}

export type UidDropMode = "auto" | "required" | "disabled";

/** Below this is the system/user range — never a sandbox or browser uid. */
export const UID_FLOOR = 100_000;
/** The sandbox block width is fixed at 10 000 uids (base..base+9999). */
const SANDBOX_UID_RANGE_WIDTH = 9_999;
const DEFAULT_SANDBOX_UID_BASE = 200_000;

/**
 * Parse OVID_SANDBOX_UID_BASE / OVID_SANDBOX_UID_MAX into the sandbox jail
 * block. Deliberately mirrors `parseUidRange` in
 * packages/sandbox/src/config.ts (the source of truth for the jail block);
 * the browser package cannot import @ovid/sandbox without adding a workspace
 * dependency edge, and the values are pinned by spec §11. Keep the two
 * validators in sync — browser tests pin the production and staging blocks.
 */
export function parseSandboxUidRange(raw: NodeJS.ProcessEnv): [number, number] {
  const baseRaw = raw.OVID_SANDBOX_UID_BASE;
  let base = DEFAULT_SANDBOX_UID_BASE;
  if (baseRaw !== undefined && baseRaw !== "") {
    const n = Number(baseRaw);
    if (!Number.isInteger(n) || n < UID_FLOOR) {
      throw new Error(
        `OVID config: OVID_SANDBOX_UID_BASE must be an integer >= ${UID_FLOOR}, got ${JSON.stringify(baseRaw)}`,
      );
    }
    base = n;
  }
  const maxRaw = raw.OVID_SANDBOX_UID_MAX;
  let max = base + SANDBOX_UID_RANGE_WIDTH;
  if (maxRaw !== undefined && maxRaw !== "") {
    const n = Number(maxRaw);
    if (!Number.isInteger(n)) {
      throw new Error(
        `OVID config: OVID_SANDBOX_UID_MAX must be an integer, got ${JSON.stringify(maxRaw)}`,
      );
    }
    max = n;
  }
  if (max <= base || max > base + SANDBOX_UID_RANGE_WIDTH) {
    throw new Error(
      `OVID config: OVID_SANDBOX_UID_MAX must satisfy base < OVID_SANDBOX_UID_MAX <= base + ${SANDBOX_UID_RANGE_WIDTH} (base=${base}), got ${max}`,
    );
  }
  return [base, max];
}

/**
 * Parse OVID_BROWSER_EGRESS_UID ("230000" or "230000-230099"). Validates the
 * uid floor AND that the range is disjoint from the sandbox jail block. The
 * engine uses the first uid; the renderer keys the whole range.
 */
export function parseBrowserUidEnv(
  value: string | undefined,
  sandboxRange: [number, number],
): { uid: number | null; range: [number, number] | null } {
  if (value === undefined || value.trim() === "") return { uid: null, range: null };
  const v = value.trim();
  const bad = (): Error =>
    new Error(
      `OVID config: OVID_BROWSER_EGRESS_UID must be a single uid ("230000") or a range ("230000-230099") of integers >= ${UID_FLOOR}, got ${JSON.stringify(value)}`,
    );
  const m = /^(\d+)(?:-(\d+))?$/.exec(v);
  if (m === null) throw bad();
  const a = Number(m[1]);
  const b = m[2] === undefined ? a : Number(m[2]);
  if (
    !Number.isSafeInteger(a) ||
    !Number.isSafeInteger(b) ||
    a < UID_FLOOR ||
    b < UID_FLOOR ||
    b < a
  ) {
    throw bad();
  }
  const [sandboxBase, sandboxMax] = sandboxRange;
  if (a <= sandboxMax && sandboxBase <= b) {
    throw new Error(
      `OVID config: OVID_BROWSER_EGRESS_UID [${a}, ${b}] overlaps the sandbox uid block [${sandboxBase}, ${sandboxMax}] — the browser engine must use a distinct uid keyspace`,
    );
  }
  return { uid: a, range: [a, b] };
}

function parseUidDropMode(raw: NodeJS.ProcessEnv): UidDropMode {
  const v = raw.OVID_BROWSER_UID_DROP?.trim();
  if (v === undefined || v === "") return "auto";
  if (v === "auto" || v === "required" || v === "disabled") return v;
  throw new Error(
    `OVID config: OVID_BROWSER_UID_DROP must be "auto", "required" or "disabled", got ${JSON.stringify(raw.OVID_BROWSER_UID_DROP)}`,
  );
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

/** Like positiveInt, but 0 is meaningful (e.g. "disable the grace window"). */
function nonNegativeInt(env: NodeJS.ProcessEnv, name: string): number | undefined {
  const raw = env[name];
  if (raw === undefined || raw === "") return undefined;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) {
    throw new Error(`${name} must be a non-negative integer (got "${raw}")`);
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
  const nodeEnv = raw.NODE_ENV?.trim() || "development";
  const production = nodeEnv === "production";
  const sandboxUidRange = parseSandboxUidRange(raw);
  const uidDropMode = parseUidDropMode(raw);
  const browserUid = parseBrowserUidEnv(raw.OVID_BROWSER_EGRESS_UID, sandboxUidRange);

  if (uidDropMode === "disabled") {
    // An explicit opt-out is allowed for dev/test only. In production it is
    // refused: "never silently root" is not enough — a config that makes the
    // nftables browser rule inert must not boot.
    if (production) {
      throw new Error(
        "OVID config: OVID_BROWSER_UID_DROP=disabled is refused when NODE_ENV=production — browser processes must run under OVID_BROWSER_EGRESS_UID, not as root",
      );
    }
    if (browserUid.uid !== null) {
      throw new Error(
        "OVID config: OVID_BROWSER_EGRESS_UID is set but OVID_BROWSER_UID_DROP=disabled — the rendered nftables browser rule would be inert; unset one of them",
      );
    }
  } else if (browserUid.uid === null && (uidDropMode === "required" || production)) {
    throw new Error(
      "OVID config: OVID_BROWSER_EGRESS_UID is required" +
        (production ? " when NODE_ENV=production" : " when OVID_BROWSER_UID_DROP=required") +
        " — browser processes must not run as root; set a dedicated uid (e.g. 230000) outside the sandbox block",
    );
  }

  return {
    maxLiveBrowsers: positiveInt(raw, "MAX_LIVE_BROWSERS") ?? 4,
    // Spec §8 default is 45 s; 0 disables the inactivity conversion.
    watchIdleHeadlessMs: nonNegativeInt(raw, "OVID_WATCH_IDLE_HEADLESS_MS") ?? 45_000,
    tier1FallbackContexts: positiveInt(raw, "MAX_TIER1_FALLBACK_CONTEXTS") ?? 2,
    idleEvictMs: positiveInt(raw, "BROWSER_IDLE_EVICT_MS") ?? 15_000,
    // The deploy env files (worker.env / .env.staging.example) spell this
    // OVID_MAX_TIER1_PROCESSES; the loader only read MAX_TIER1_PROCESSES, so
    // the configured 128 was silently ignored and the default 8 applied
    // (capacity wave 2026-10-19). Both spellings are honoured; OVID_ wins.
    maxTier1Processes:
      positiveInt(raw, "OVID_MAX_TIER1_PROCESSES") ?? positiveInt(raw, "MAX_TIER1_PROCESSES") ?? 8,
    tier1TimeoutMs: positiveInt(raw, "TIER1_TIMEOUT_MS") ?? 20_000,
    maxActiveScreencasts: positiveInt(raw, "MAX_ACTIVE_SCREENCASTS") ?? 3,
    screencastLoadMax: positiveNumber(raw, "OVID_SCREENCAST_LOAD_MAX") ?? 6.0,
    screencastDetachGraceMs: nonNegativeInt(raw, "OVID_SCREENCAST_DETACH_GRACE_MS") ?? 45_000,
    screencast: {
      width: positiveInt(raw, "OVID_SCREENCAST_WIDTH") ?? 1280,
      height: positiveInt(raw, "OVID_SCREENCAST_HEIGHT") ?? 800,
      quality: positiveInt(raw, "OVID_SCREENCAST_QUALITY") ?? 60,
      everyNthFrame: positiveInt(raw, "OVID_SCREENCAST_EVERY_NTH_FRAME") ?? 2,
      maxFramesInFlight: positiveInt(raw, "OVID_SCREENCAST_MAX_FRAMES_IN_FLIGHT") ?? 1,
      // Spec §8: the live view is 3–5 fps, default 4. Clamp so a typo'd env
      // value can never turn the stream into a slideshow or a 30 fps firehose.
      maxFps: clampScreencastFps(positiveNumber(raw, "OVID_SCREENCAST_MAX_FPS")),
    },
    stateDir: optionalString(raw, "OVID_BROWSER_STATE_DIR"),
    lightpandaBin: optionalString(raw, "OVID_LIGHTPANDA_BIN"),
    // OVID_BROWSER_ALLOW_HOSTS is a tests/dev escape hatch. In production a
    // single mistyped entry would open SSRF (e.g. 127.0.0.1), so the env var
    // is ignored entirely when NODE_ENV=production.
    allowHosts: production
      ? []
      : (raw.OVID_BROWSER_ALLOW_HOSTS ?? "")
          .split(",")
          .map((h) => h.trim())
          .filter((h) => h !== ""),
    ownPublicIp: optionalString(raw, "OVID_PUBLIC_IP"),
    blockHeavyResources: (raw.OVID_BROWSER_BLOCK_HEAVY_RESOURCES ?? "1") !== "0",
    // Resource diet (Muse ephemeral-lease model): a small V8 heap, at most
    // two renderers, no extensions/background networking/media. The per-
    // context cost measured ~240 MB before; the diet plus the 15 s lease is
    // what makes 60-100 simultaneous contexts fit instead of 4.
    chromiumArgs: [
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--js-flags=--max-old-space-size=96",
      "--renderer-process-limit=2",
      "--disable-extensions",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-default-apps",
      "--disable-sync",
      "--mute-audio",
      "--no-first-run",
      "--no-default-browser-check",
    ],
    egressUid: browserUid.uid,
    browserUidRange: browserUid.range,
    sandboxUidRange,
    uidDropMode,
  };
}
