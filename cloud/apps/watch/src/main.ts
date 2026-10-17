import { mkdir, readFile, rename, statfs, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Redis } from "ioredis";
import postgres from "postgres";
import { runSelfTest, sendAlert, type AlertSink } from "./alertSink.js";
import { diffStates } from "./alertState.js";
import {
  collectChecks,
  type CheckResult,
  type SpendRow,
  type WatchDeps,
} from "./checks.js";
import { loadWatchEnv, type WatchEnv } from "./env.js";

/**
 * `@ovid/watch` — one-shot monitor driven by a systemd timer.
 *
 * Every invocation: collect checks → diff against the persisted state →
 * deliver only EDGES (new failure, 30-min reminder, recovery) → persist.
 * `--self-test` proves the configured alert sink end to end and exits nonzero
 * unless the send succeeded.
 *
 * No real alert is ever sent by tests: deps and the sink are injectable.
 */

export interface MainOptions {
  log?: (line: string) => void;
  /** Test seam; production uses the global fetch. */
  fetchImpl?: typeof fetch;
  /** Injected clock (deterministic state-diff tests). */
  now?: () => Date;
  /** Injected check seams (tests); production builds the real ones. */
  deps?: WatchDeps;
  /** Injected alert sink (tests); production builds it from env. */
  sink?: AlertSink;
}

interface PersistedState {
  states: Record<string, boolean>;
  lastAlertAt: Record<string, number>;
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function parseInfo(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split(/\r?\n/)) {
    if (line === "" || line.startsWith("#")) continue;
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    out[line.slice(0, colon)] = line.slice(colon + 1);
  }
  return out;
}

export interface WatchRuntimeDeps {
  deps: WatchDeps;
  close: () => Promise<void>;
}

/** Real side-effect wiring (redis-q, mint db2, LiteLLM Postgres, disk). */
export function createWatchDeps(
  env: WatchEnv,
  log: (line: string) => void = () => {},
): WatchRuntimeDeps {
  const redisQ = new Redis(env.redisQUrl, { maxRetriesPerRequest: 2 });
  redisQ.on("error", (err: unknown) => log(`[watch] redis-q error: ${errorMessage(err)}`));

  const redisMint =
    env.spendParity && env.mintRedisUrl !== ""
      ? new Redis(env.mintRedisUrl, { maxRetriesPerRequest: 2 })
      : null;
  redisMint?.on("error", (err: unknown) =>
    log(`[watch] redis-mint error: ${errorMessage(err)}`),
  );

  const sqlClient =
    env.spendParity && env.litellmDatabaseUrl !== ""
      ? postgres(env.litellmDatabaseUrl, { max: 1, onnotice: () => {} })
      : null;

  const waitKey = (queue: string): string => `${env.queuePrefix}:${queue}:wait`;
  const jobKey = (queue: string, id: string): string =>
    `${env.queuePrefix}:${queue}:${id}`;

  const deps: WatchDeps = {
    async fetchJson(url: string): Promise<unknown> {
      const res = await fetch(url, {
        signal: AbortSignal.timeout(env.httpTimeoutMs),
      });
      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }
      return res.json();
    },

    async redisInfo(section: string): Promise<Record<string, string>> {
      return parseInfo(await redisQ.info(section));
    },

    async queueWaiting(name: string): Promise<number> {
      const len = await redisQ.llen(waitKey(name));
      return Number(len);
    },

    async queueOldestWaitingAgeS(name: string): Promise<number> {
      // BullMQ keeps waiting jobs in `{prefix}:{queue}:wait` (oldest first);
      // each job hash carries `timestamp` (enqueue epoch ms).
      const id = await redisQ.lindex(waitKey(name), 0);
      if (id === null) return 0;
      const ts = await redisQ.hget(jobKey(name, id), "timestamp");
      const enqueuedMs = Number(ts);
      if (ts === null || !Number.isFinite(enqueuedMs)) return 0;
      return Math.max(0, Math.round((Date.now() - enqueuedMs) / 1000));
    },

    async sql<T>(q: string): Promise<T[]> {
      if (sqlClient === null) {
        throw new Error("WATCH_LITELLM_DATABASE_URL is not configured");
      }
      return (await sqlClient.unsafe(q)) as unknown as T[];
    },

    async dfPct(path: string): Promise<number> {
      const stats = await statfs(path);
      const total = Number(stats.blocks);
      if (!Number.isFinite(total) || total <= 0) return 0;
      const free = Number(stats.bfree);
      return ((total - free) / total) * 100;
    },

    now(): Date {
      return new Date();
    },

    config: {
      queueNames: env.queueNames,
      gatewayHealthUrl: env.gatewayHealthUrl,
      diskPath: env.diskPath,
      spendParity: env.spendParity,
      thresholds: env.thresholds,
    },

    async mintSpendCents(): Promise<SpendRow[]> {
      if (redisMint === null) {
        throw new Error("REDIS_MINT_URL is not configured");
      }
      const rows: SpendRow[] = [];
      let cursor = "0";
      do {
        const [next, keys] = await redisMint.scan(
          cursor,
          "MATCH",
          "pool:*:spend",
          "COUNT",
          500,
        );
        cursor = next;
        if (keys.length > 0) {
          const values = await redisMint.mget(...keys);
          keys.forEach((key, index) => {
            const match = /^pool:(.+):spend$/.exec(key);
            if (match === null) return;
            const usd = Number(values[index]);
            if (Number.isFinite(usd)) {
              rows.push({ uid: match[1], cents: Math.round(usd * 100) });
            }
          });
        }
      } while (cursor !== "0");
      return rows;
    },
  };

  return {
    deps,
    async close(): Promise<void> {
      await Promise.allSettled([
        redisQ.quit(),
        redisMint !== null ? redisMint.quit() : Promise.resolve(),
        sqlClient !== null ? sqlClient.end({ timeout: 5 }) : Promise.resolve(),
      ]);
    },
  };
}

async function readState(file: string, log: (line: string) => void): Promise<PersistedState> {
  try {
    const parsed = JSON.parse(await readFile(file, "utf8")) as Partial<PersistedState>;
    return {
      states:
        parsed.states !== null && typeof parsed.states === "object"
          ? (parsed.states as Record<string, boolean>)
          : {},
      lastAlertAt:
        parsed.lastAlertAt !== null && typeof parsed.lastAlertAt === "object"
          ? (parsed.lastAlertAt as Record<string, number>)
          : {},
    };
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") {
      log(`[watch] state file unreadable (${errorMessage(err)}); starting fresh`);
    }
    return { states: {}, lastAlertAt: {} };
  }
}

async function writeState(file: string, state: PersistedState): Promise<void> {
  await mkdir(dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  await writeFile(tmp, `${JSON.stringify(state, null, 2)}\n`, "utf8");
  await rename(tmp, file);
}

function formatAlert(check: CheckResult, now: Date): string {
  return `ALERT ${check.name}: ${check.detail} (value ${check.value}, threshold ${check.threshold}) at ${now.toISOString()}`;
}

function formatRecovery(check: CheckResult, now: Date): string {
  return `RECOVERED ${check.name}: ${check.detail} at ${now.toISOString()}`;
}

function buildSink(env: WatchEnv, log: (line: string) => void): AlertSink {
  return {
    telegram:
      env.telegramBotToken !== "" && env.telegramChatId !== ""
        ? { botToken: env.telegramBotToken, chatId: env.telegramChatId }
        : undefined,
    webhookUrl: env.webhookUrl !== "" ? env.webhookUrl : undefined,
    log,
  };
}

export async function main(
  argvOrEnv: string[] | NodeJS.ProcessEnv = process.argv.slice(2),
  rawEnv: NodeJS.ProcessEnv = process.env,
  opts: MainOptions = {},
): Promise<number> {
  // The plan pins `main(env)`; the process entry passes argv. Accept both so
  // the library form stays exactly the documented one.
  const argv = Array.isArray(argvOrEnv) ? argvOrEnv : [];
  const envSource = Array.isArray(argvOrEnv) ? rawEnv : argvOrEnv;
  const log = opts.log ?? ((line: string) => console.log(line));
  const selfTest = argv.includes("--self-test");

  let env: WatchEnv;
  try {
    env = loadWatchEnv(envSource, { requireBackends: !selfTest });
  } catch (err) {
    log(`[watch] config error: ${errorMessage(err)}`);
    return 1;
  }

  const sink = opts.sink ?? buildSink(env, log);
  const sendOpts = {
    fetchImpl: opts.fetchImpl,
    timeoutMs: env.httpTimeoutMs,
  };

  if (selfTest) {
    try {
      const text = await runSelfTest(sink, {
        ...sendOpts,
        ...(opts.now !== undefined ? { now: opts.now() } : {}),
      });
      log(`[watch] self-test OK: ${text}`);
      return 0;
    } catch (err) {
      log(`[watch] self-test FAILED: ${errorMessage(err)}`);
      return 1;
    }
  }

  const now = opts.now?.() ?? new Date();
  let deps = opts.deps;
  let close: () => Promise<void> = async () => {};
  if (deps === undefined) {
    const runtime = createWatchDeps(env, log);
    deps = runtime.deps;
    close = runtime.close;
  }

  try {
    const prev = await readState(env.stateFile, log);
    const results = await collectChecks(deps);
    const diff = diffStates(prev.states, results, {
      now,
      repeatAfterMs: env.repeatAfterMs,
      lastAlertAt: prev.lastAlertAt,
    });

    for (const check of results) {
      log(
        `[watch] check ${check.name}: ${check.ok ? "ok" : "FAIL"} value=${check.value} threshold=${check.threshold} ${check.detail}`,
      );
    }

    let code = 0;
    const delivered = new Set<string>();
    for (const alert of diff.alerts) {
      try {
        await sendAlert(sink, formatAlert(alert, now), sendOpts);
        delivered.add(alert.name);
        log(`ALERT ${alert.name}: ${alert.detail}`);
      } catch (err) {
        code = 1;
        log(`[watch] alert delivery failed for ${alert.name}: ${errorMessage(err)}`);
      }
    }
    for (const recovery of diff.recovered) {
      try {
        await sendAlert(sink, formatRecovery(recovery, now), sendOpts);
        log(`RECOVERED ${recovery.name}: ${recovery.detail}`);
      } catch (err) {
        code = 1;
        log(`[watch] recovery delivery failed for ${recovery.name}: ${errorMessage(err)}`);
      }
    }

    // Only successfully delivered alerts get a NEW timestamp; a failed send
    // stays pending so the next timer tick retries the edge (never swallowed).
    // Quiet failing checks carry their existing timestamp forward.
    const attempted = new Set<string>(diff.alerts.map((alert) => alert.name));
    const nextAlertAt: Record<string, number> = {};
    for (const [name, at] of Object.entries(diff.nextAlertAt)) {
      if (!attempted.has(name) || delivered.has(name)) nextAlertAt[name] = at;
    }
    await writeState(env.stateFile, {
      states: diff.nextState,
      lastAlertAt: nextAlertAt,
    });

    log(
      `[watch] pass: ${results.length} checks, ${diff.alerts.length} alerts, ${diff.recovered.length} recoveries`,
    );
    return code;
  } catch (err) {
    log(`[watch] run failed: ${errorMessage(err)}`);
    return 1;
  } finally {
    await close();
  }
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly) {
  main(process.argv.slice(2))
    .then((code) => {
      process.exitCode = code;
    })
    .catch((err: unknown) => {
      console.error(`[watch] fatal: ${errorMessage(err)}`);
      process.exitCode = 1;
    });
}
