import {
  DEFAULT_DISK_PATH,
  DEFAULT_GATEWAY_HEALTH_URL,
  DEFAULT_QUEUE_NAMES,
  DEFAULT_THRESHOLDS,
  type WatchThresholds,
} from "./checks.js";
import { DEFAULT_REPEAT_AFTER_MS } from "./alertState.js";

/**
 * Watch environment. Every default is the plan's locked value; every parse
 * error names the offending variable (the P1/P9 convention). The loader is
 * strict on purpose: a monitor pointed at the wrong redis/postgres or with a
 * half-configured sink must refuse to start, not run blind.
 */
export interface WatchEnv {
  stateFile: string;
  gatewayHealthUrl: string;
  redisQUrl: string;
  queuePrefix: string;
  queueNames: string[];
  diskPath: string;
  thresholds: WatchThresholds;
  repeatAfterMs: number;
  spendParity: boolean;
  /** Read-only connection to LiteLLM's Postgres (LiteLLM_SpendLogs). */
  litellmDatabaseUrl: string;
  /** Mint db2 projection URL (carries the db selector, e.g. …/2). */
  mintRedisUrl: string;
  telegramBotToken: string;
  telegramChatId: string;
  webhookUrl: string;
  httpTimeoutMs: number;
}

export const DEFAULT_STATE_FILE = "/var/lib/ovid-cloud-watch/state.json";

function rawString(raw: NodeJS.ProcessEnv, name: string, fallback: string): string {
  const value = raw[name];
  return value === undefined || value === "" ? fallback : value;
}

function requiredString(raw: NodeJS.ProcessEnv, name: string): string {
  const value = raw[name];
  if (value === undefined || value.trim() === "") {
    throw new Error(`${name} is required`);
  }
  return value;
}

function intVar(
  raw: NodeJS.ProcessEnv,
  name: string,
  fallback: number,
  min = 0,
): number {
  const value = raw[name];
  if (value === undefined || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || !Number.isInteger(parsed) || parsed < min) {
    throw new Error(`${name} must be an integer >= ${min} (got ${JSON.stringify(value)})`);
  }
  return parsed;
}

function boolVar(raw: NodeJS.ProcessEnv, name: string, fallback: boolean): boolean {
  const value = raw[name];
  if (value === undefined || value === "") return fallback;
  switch (value.trim().toLowerCase()) {
    case "1":
    case "true":
    case "on":
    case "yes":
      return true;
    case "0":
    case "false":
    case "off":
    case "no":
      return false;
    default:
      throw new Error(`${name} must be on/off (got ${JSON.stringify(value)})`);
  }
}

function queueNames(raw: NodeJS.ProcessEnv): string[] {
  const value = raw["WATCH_QUEUE_NAMES"];
  if (value === undefined || value.trim() === "") return [...DEFAULT_QUEUE_NAMES];
  const names = value
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part !== "");
  return names.length > 0 ? names : [...DEFAULT_QUEUE_NAMES];
}

/**
 * @param opts.requireBackends false only for `--self-test`, whose job is to
 * prove the ALERT path (it must be runnable before redis/postgres wiring is
 * finalised). Normal runs require the backends and the spend ledger pair.
 */
export function loadWatchEnv(
  raw: NodeJS.ProcessEnv = process.env,
  opts: { requireBackends?: boolean } = {},
): WatchEnv {
  const requireBackends = opts.requireBackends ?? true;

  const telegramBotToken = rawString(raw, "ALERT_TELEGRAM_BOT_TOKEN", "");
  const telegramChatId = rawString(raw, "ALERT_TELEGRAM_CHAT_ID", "");
  const webhookUrl = rawString(raw, "OVID_ALERT_WEBHOOK_URL", "");

  if (telegramBotToken !== "" && telegramChatId === "") {
    throw new Error("ALERT_TELEGRAM_CHAT_ID is required when ALERT_TELEGRAM_BOT_TOKEN is set");
  }
  if (telegramChatId !== "" && telegramBotToken === "") {
    throw new Error("ALERT_TELEGRAM_BOT_TOKEN is required when ALERT_TELEGRAM_CHAT_ID is set");
  }
  if (telegramBotToken === "" && webhookUrl === "") {
    throw new Error(
      "no alert sink configured: set ALERT_TELEGRAM_BOT_TOKEN + ALERT_TELEGRAM_CHAT_ID or OVID_ALERT_WEBHOOK_URL",
    );
  }

  const spendParity = boolVar(raw, "WATCH_SPEND_PARITY", true);
  const litellmDatabaseUrl = rawString(raw, "WATCH_LITELLM_DATABASE_URL", "");
  const mintRedisUrl = rawString(raw, "REDIS_MINT_URL", "");

  let redisQUrl = "";
  if (requireBackends) {
    redisQUrl = requiredString(raw, "REDIS_Q_URL");
    if (spendParity && litellmDatabaseUrl === "") {
      throw new Error(
        "WATCH_LITELLM_DATABASE_URL is required when WATCH_SPEND_PARITY=on (set it to a read-only LiteLLM Postgres URL, or set WATCH_SPEND_PARITY=off)",
      );
    }
    if (spendParity && mintRedisUrl === "") {
      throw new Error(
        "REDIS_MINT_URL is required when WATCH_SPEND_PARITY=on (set it to the mint db2 projection URL, or set WATCH_SPEND_PARITY=off)",
      );
    }
  } else {
    redisQUrl = rawString(raw, "REDIS_Q_URL", "");
  }

  return {
    stateFile: rawString(raw, "WATCH_STATE_FILE", DEFAULT_STATE_FILE),
    gatewayHealthUrl: rawString(
      raw,
      "GATEWAY_HEALTH_URL",
      DEFAULT_GATEWAY_HEALTH_URL,
    ),
    redisQUrl,
    queuePrefix: rawString(raw, "WATCH_QUEUE_PREFIX", "bull"),
    queueNames: queueNames(raw),
    diskPath: rawString(raw, "WATCH_DISK_PATH", DEFAULT_DISK_PATH),
    thresholds: {
      queueWaiting: intVar(raw, "WATCH_QUEUE_WAITING", DEFAULT_THRESHOLDS.queueWaiting, 0),
      workerLagS: intVar(raw, "WATCH_WORKER_LAG_S", DEFAULT_THRESHOLDS.workerLagS, 0),
      diskPct: intVar(raw, "WATCH_DISK_PCT", DEFAULT_THRESHOLDS.diskPct, 1),
      redisMemPct: intVar(raw, "WATCH_REDIS_MEM_PCT", DEFAULT_THRESHOLDS.redisMemPct, 1),
      spendDriftCents: intVar(
        raw,
        "WATCH_SPEND_DRIFT_CENTS",
        DEFAULT_THRESHOLDS.spendDriftCents,
        0,
      ),
      spendDriftPct: intVar(raw, "WATCH_SPEND_DRIFT_PCT", DEFAULT_THRESHOLDS.spendDriftPct, 0),
    },
    repeatAfterMs:
      intVar(raw, "WATCH_REPEAT_AFTER_S", DEFAULT_REPEAT_AFTER_MS / 1000, 1) * 1000,
    spendParity,
    litellmDatabaseUrl,
    mintRedisUrl,
    telegramBotToken,
    telegramChatId,
    webhookUrl,
    httpTimeoutMs: intVar(raw, "WATCH_HTTP_TIMEOUT_MS", 5_000, 1),
  };
}
