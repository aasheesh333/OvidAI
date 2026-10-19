import { execFile, fork } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { Redis } from "ioredis";
import { createDb } from "@ovid/db";
import { runCapacityShard, windowOf, type CapacityProfile, type ShardResult } from "./capacity.js";
import { LatencyHistogram } from "./hdr.js";

/**
 * Capacity CLI (2026-10-19).
 *
 *   node apps/load/dist/capacityCli.js --users 1800 --shards 4 \
 *     --measure-ms 900000 --burst-at-ms 300000 --label after-1800 \
 *     --json reports/capacity/after-1800.json
 *
 * Parent: forks `--shards` child processes (each runs runCapacityShard over
 * users/shards users against the same timeline epoch), samples the staging
 * stack every 5 s (host CPU/RAM, staging containers via `docker stats`, the
 * host staging worker via /proc, redis-q INFO, Postgres connections + sizes,
 * disk under the staging roots) and merges everything into one JSON.
 *
 * Read-only against the stack it measures; it only ever talks to the URLs
 * given (defaults: the isolated staging composition's loopback ports).
 */

interface Args {
  users: number;
  shards: number;
  rampMs: number;
  settleMs: number;
  measureMs: number;
  sendMinMs: number;
  sendMaxMs: number;
  toolShare: number;
  studioShare: number;
  studioEveryMs: number;
  browserUsers: number;
  burstAtMs: number | null;
  burstWindowMs: number;
  runTimeoutMs: number;
  baseUrl: string;
  redisUrl: string;
  databaseUrl: string;
  workerPidFile: string;
  containerPrefix: string;
  diskPaths: string[];
  label: string;
  json: string | null;
  /** Worker file service for direct Studio reads (token: env CAP_INTERNAL_TOKEN). */
  workerFileUrl: string | null;
  envFile: string | null;
}

function parseArgs(argv: string[]): Args {
  const a: Args = {
    users: 1800,
    shards: 4,
    rampMs: 120_000,
    settleMs: 30_000,
    measureMs: 300_000,
    sendMinMs: 20_000,
    sendMaxMs: 60_000,
    toolShare: 0.2,
    studioShare: 0.05,
    studioEveryMs: 15_000,
    browserUsers: 48,
    burstAtMs: null,
    burstWindowMs: 1_000,
    runTimeoutMs: 90_000,
    baseUrl: "http://127.0.0.1:18082",
    redisUrl: process.env.CAP_REDIS_URL ?? "redis://:staging@127.0.0.1:16379",
    databaseUrl: process.env.CAP_DATABASE_URL ?? "postgres://postgres:staging@127.0.0.1:15432/ovid_cloud_staging",
    workerPidFile: "/tmp/opencode/ovid-staging-worker.pid",
    containerPrefix: "ovid-cloud-staging-",
    diskPaths: ["/workspaces-staging"],
    label: "capacity",
    json: null,
    workerFileUrl: null,
    envFile: null,
  };
  const num = (v: string | undefined, name: string): number => {
    const n = Number(v);
    if (v === undefined || !Number.isFinite(n)) throw new Error(`capacity: ${name} needs a number`);
    return n;
  };
  for (let i = 0; i < argv.length; i += 1) {
    const k = argv[i]!;
    const v = argv[i + 1];
    i += 1;
    switch (k) {
      case "--users": a.users = num(v, k); break;
      case "--shards": a.shards = num(v, k); break;
      case "--ramp-ms": a.rampMs = num(v, k); break;
      case "--settle-ms": a.settleMs = num(v, k); break;
      case "--measure-ms": a.measureMs = num(v, k); break;
      case "--send-min-ms": a.sendMinMs = num(v, k); break;
      case "--send-max-ms": a.sendMaxMs = num(v, k); break;
      case "--tool-share": a.toolShare = num(v, k); break;
      case "--studio-share": a.studioShare = num(v, k); break;
      case "--studio-every-ms": a.studioEveryMs = num(v, k); break;
      case "--browser-users": a.browserUsers = num(v, k); break;
      case "--burst-at-ms": a.burstAtMs = num(v, k); break;
      case "--burst-window-ms": a.burstWindowMs = num(v, k); break;
      case "--run-timeout-ms": a.runTimeoutMs = num(v, k); break;
      case "--base-url": a.baseUrl = v!; break;
      case "--redis-url": a.redisUrl = v!; break;
      case "--database-url": a.databaseUrl = v!; break;
      case "--worker-pidfile": a.workerPidFile = v!; break;
      case "--container-prefix": a.containerPrefix = v!; break;
      case "--disk": a.diskPaths = v!.split(","); break;
      case "--label": a.label = v!; break;
      case "--json": a.json = v!; break;
      case "--worker-file-url": a.workerFileUrl = v!; break;
      case "--env-file": a.envFile = v!; break;
      default: throw new Error(`capacity: unknown argument ${k}`);
    }
  }
  return a;
}

function sh(cmd: string, args: string[], timeoutMs = 20_000): Promise<string> {
  return new Promise((res) => {
    execFile(cmd, args, { encoding: "utf8", timeout: timeoutMs, maxBuffer: 8 << 20 }, (err, out) =>
      res(err ? "" : out),
    );
  });
}

/** Strip credentials even from malformed connection strings. */
export function redactConnectionUrl(value: string): string {
  try {
    const url = new URL(value);
    if (url.password !== "") url.password = "REDACTED";
    return url.toString();
  } catch { return "[invalid URL]"; }
}

/** "1.2GiB / 2GiB" → MiB of the first figure. */
export function parseMemMiB(usage: string): number | null {
  const m = /^([\d.]+)\s*(B|kB|KiB|MB|MiB|GB|GiB)/i.exec(usage.trim());
  if (m === null) return null;
  const n = Number(m[1]);
  switch (m[2]!.toLowerCase()) {
    case "b": return n / 1048576;
    case "kb": case "kib": return n / 1024;
    case "mb": case "mib": return n;
    case "gb": case "gib": return n * 1024;
    default: return null;
  }
}

interface Sample {
  t: number;
  hostCpuPct: number;
  memAvailableMb: number;
  swapUsedMb: number;
  containers: Record<string, { cpuPct: number; memMb: number }>;
  workerCpuPct: number;
  workerRssMb: number;
  redisUsedMb: number;
  redisClients: number;
  redisKeys: number;
  pgConnections: number;
  pgDbMb: number;
  pgMirrorMb: number;
  diskMb?: Record<string, number>;
}

async function readCpu(): Promise<{ busy: number; total: number }> {
  const stat = await readFile("/proc/stat", "utf8");
  const parts = stat.split("\n")[0]!.trim().split(/\s+/).slice(1).map(Number);
  const idle = (parts[3] ?? 0) + (parts[4] ?? 0);
  const total = parts.reduce((s, v) => s + v, 0);
  return { busy: total - idle, total };
}

async function procTicks(pid: number): Promise<{ ticks: number; rssMb: number } | null> {
  try {
    const stat = await readFile(`/proc/${pid}/stat`, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    const ticks = Number(fields[11]) + Number(fields[12]);
    const status = await readFile(`/proc/${pid}/status`, "utf8");
    const rss = /VmRSS:\s+(\d+)/.exec(status);
    return { ticks, rssMb: rss === null ? 0 : Number(rss[1]) / 1024 };
  } catch {
    return null;
  }
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv[0] === "--child") {
    const payload = JSON.parse(argv[1]!) as Parameters<typeof runCapacityShard>[0];
    const result = await runCapacityShard(payload);
    process.send?.(result);
    // Let the IPC message flush before exiting.
    setTimeout(() => process.exit(0), 200);
    return;
  }

  const a = parseArgs(argv);
  // Token for direct Studio reads: CAP_INTERNAL_TOKEN, else OVID_INTERNAL_TOKEN
  // parsed (never sourced) from --env-file (the staging env file).
  let internalToken = process.env.CAP_INTERNAL_TOKEN ?? "";
  if (internalToken === "" && a.envFile !== null) {
    const text = await readFile(a.envFile, "utf8");
    internalToken = /^OVID_INTERNAL_TOKEN=(.*)$/m.exec(text)?.[1]?.trim() ?? "";
  }
  const runTag = `cap-${Date.now().toString(36)}`;
  const epochMs = Date.now() + 3_000;
  const win = windowOf({ rampMs: a.rampMs, settleMs: a.settleMs, measureMs: a.measureMs });
  const wsBase = `${a.baseUrl.replace(/^http/, "ws")}/cloud/ws`;

  // ---- sampler ------------------------------------------------------------
  const redis = new Redis(a.redisUrl, { maxRetriesPerRequest: 1, lazyConnect: false });
  redis.on("error", () => {});
  const sql = createDb(a.databaseUrl).$client;
  const samples: Sample[] = [];
  let workerPid = 0;
  try {
    workerPid = Number((await readFile(a.workerPidFile, "utf8")).trim());
  } catch {
    workerPid = 0;
  }
  let sampling = true;
  const hz = 100;
  const sampler = (async () => {
    let prevCpu = await readCpu();
    let prevWorker = workerPid > 0 ? await procTicks(workerPid) : null;
    let prevT = Date.now();
    let lastDisk = 0;
    while (sampling) {
      await new Promise((r) => setTimeout(r, 5_000));
      const t = Date.now();
      const cpu = await readCpu();
      const hostCpuPct = (100 * (cpu.busy - prevCpu.busy)) / Math.max(1, cpu.total - prevCpu.total);
      prevCpu = cpu;
      const meminfo = await readFile("/proc/meminfo", "utf8");
      const kb = (k: string): number => Number(new RegExp(`^${k}:\\s+(\\d+)`, "m").exec(meminfo)?.[1] ?? 0);
      const containers: Sample["containers"] = {};
      const stats = await sh("docker", ["stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"]);
      for (const line of stats.split("\n")) {
        const [name, cpuPct, mem] = line.split("\t");
        if (name === undefined || !name.startsWith(a.containerPrefix) || mem === undefined) continue;
        containers[name.slice(a.containerPrefix.length)] = {
          cpuPct: Number(cpuPct?.replace("%", "")) || 0,
          memMb: Math.round(parseMemMiB(mem) ?? 0),
        };
      }
      let workerCpuPct = 0;
      let workerRssMb = 0;
      const w = workerPid > 0 ? await procTicks(workerPid) : null;
      if (w !== null && prevWorker !== null) {
        workerCpuPct = ((w.ticks - prevWorker.ticks) / hz / ((t - prevT) / 1000)) * 100;
        workerRssMb = w.rssMb;
      }
      prevWorker = w;
      prevT = t;
      let redisUsedMb = 0;
      let redisClients = 0;
      let redisKeys = 0;
      try {
        const info = await redis.info();
        redisUsedMb = Number(/used_memory:(\d+)/.exec(info)?.[1] ?? 0) / 1048576;
        redisClients = Number(/connected_clients:(\d+)/.exec(info)?.[1] ?? 0);
        redisKeys = await redis.dbsize();
      } catch {
        // redis unreachable this tick
      }
      let pgConnections = 0;
      let pgDbMb = 0;
      let pgMirrorMb = 0;
      try {
        const [row] = await sql`
          SELECT (SELECT count(*) FROM pg_stat_activity WHERE datname = current_database())::int AS conns,
                 pg_database_size(current_database())::bigint AS db,
                 COALESCE(pg_total_relation_size(to_regclass('session_event_mirror')), 0)::bigint AS mirror`;
        pgConnections = Number(row?.conns ?? 0);
        pgDbMb = Number(row?.db ?? 0) / 1048576;
        pgMirrorMb = Number(row?.mirror ?? 0) / 1048576;
      } catch {
        // pg unreachable this tick
      }
      const sample: Sample = {
        t,
        hostCpuPct: Math.round(hostCpuPct * 10) / 10,
        memAvailableMb: Math.round(kb("MemAvailable") / 1024),
        swapUsedMb: Math.round((kb("SwapTotal") - kb("SwapFree")) / 1024),
        containers,
        workerCpuPct: Math.round(workerCpuPct * 10) / 10,
        workerRssMb: Math.round(workerRssMb),
        redisUsedMb: Math.round(redisUsedMb * 10) / 10,
        redisClients,
        redisKeys,
        pgConnections,
        pgDbMb: Math.round(pgDbMb * 10) / 10,
        pgMirrorMb: Math.round(pgMirrorMb * 10) / 10,
      };
      if (t - lastDisk >= 60_000) {
        lastDisk = t;
        sample.diskMb = {};
        for (const p of a.diskPaths) {
          const out = await sh("du", ["-sxm", p], 60_000);
          sample.diskMb[p] = Number(out.split(/\s+/)[0]) || 0;
        }
      }
      samples.push(sample);
      const c = Object.entries(containers)
        .map(([n, v]) => `${n}=${v.cpuPct.toFixed(0)}%/${v.memMb}M`)
        .join(" ");
      console.error(
        `[cap ${Math.round((t - epochMs) / 1000)}s] host=${sample.hostCpuPct}% avail=${sample.memAvailableMb}M ` +
          `worker=${sample.workerCpuPct}%/${sample.workerRssMb}M redis=${sample.redisUsedMb}M/${redisClients}c ` +
          `pg=${pgConnections}c ${c}`,
      );
    }
  })();

  // ---- shards -------------------------------------------------------------
  const self = fileURLToPath(import.meta.url);
  const per = Math.ceil(a.users / a.shards);
  const results = await Promise.all(
    Array.from({ length: a.shards }, (_, shard) => {
      const users = Math.max(0, Math.min(per, a.users - shard * per));
      const share = (n: number): number => Math.round((n * users) / a.users);
      const profile: CapacityProfile = {
        users,
        rampMs: a.rampMs,
        settleMs: a.settleMs,
        measureMs: a.measureMs,
        sendEveryMinMs: a.sendMinMs,
        sendEveryMaxMs: a.sendMaxMs,
        toolShare: a.toolShare,
        studioUsers: Math.round(users * a.studioShare),
        studioEveryMs: a.studioEveryMs,
        browserUsers: share(a.browserUsers),
        burst: a.burstAtMs === null ? undefined : { atMs: a.burstAtMs, windowMs: a.burstWindowMs },
        runTimeoutMs: a.runTimeoutMs,
      };
      const payload = {
        shard,
        userOffset: shard * per,
        runTag,
        epochMs,
        profile,
        target: {
          baseUrl: a.baseUrl,
          wsBase,
          workerFile:
            a.workerFileUrl !== null && internalToken !== ""
              ? { url: a.workerFileUrl, token: internalToken }
              : undefined,
        },
      };
      return new Promise<ShardResult>((res, rej) => {
        const child = fork(self, ["--child", JSON.stringify(payload)], {
          execArgv: ["--max-old-space-size=2048"],
          stdio: ["ignore", "inherit", "inherit", "ipc"],
        });
        let got: ShardResult | null = null;
        child.on("message", (m) => {
          got = m as ShardResult;
        });
        child.on("exit", (code) => (got !== null ? res(got) : rej(new Error(`shard ${shard} exit ${code}`))));
      });
    }),
  );
  sampling = false;
  await sampler;
  await redis.quit().catch(() => {});
  await sql.end({ timeout: 5 }).catch(() => {});

  // ---- merge --------------------------------------------------------------
  const names = Object.keys(results[0]!.histograms) as Array<keyof ShardResult["histograms"]>;
  const merged: Record<string, ReturnType<LatencyHistogram["summary"]>> = {};
  for (const n of names) {
    const hist = new LatencyHistogram();
    for (const r of results) hist.merge(r.histograms[n]);
    merged[n] = hist.summary();
  }
  const sum = (pick: (r: ShardResult) => Record<string, number>): Record<string, number> => {
    const out: Record<string, number> = {};
    for (const r of results) for (const [k, v] of Object.entries(pick(r))) out[k] = (out[k] ?? 0) + v;
    return out;
  };
  const counters = sum((r) => r.counters);
  const window = samples.filter((s) => s.t >= epochMs + win.startMs && s.t < epochMs + win.endMs);
  const avg = (xs: number[]): number => (xs.length === 0 ? 0 : xs.reduce((s, v) => s + v, 0) / xs.length);
  const round1 = (v: number): number => Math.round(v * 10) / 10;
  const containerNames = [...new Set(window.flatMap((s) => Object.keys(s.containers)))];
  const resources = {
    samples: window.length,
    hostCpuAvgPct: round1(avg(window.map((s) => s.hostCpuPct))),
    hostCpuMaxPct: round1(Math.max(0, ...window.map((s) => s.hostCpuPct))),
    memAvailableMinMb: Math.min(...window.map((s) => s.memAvailableMb), Number.MAX_SAFE_INTEGER),
    swapUsedMaxMb: Math.max(0, ...window.map((s) => s.swapUsedMb)),
    workerCpuAvgPct: round1(avg(window.map((s) => s.workerCpuPct))),
    workerCpuMaxPct: round1(Math.max(0, ...window.map((s) => s.workerCpuPct))),
    workerRssFirstMb: window[0]?.workerRssMb ?? 0,
    workerRssMaxMb: Math.max(0, ...window.map((s) => s.workerRssMb)),
    workerRssLastMb: window.at(-1)?.workerRssMb ?? 0,
    redisUsedFirstMb: window[0]?.redisUsedMb ?? 0,
    redisUsedLastMb: window.at(-1)?.redisUsedMb ?? 0,
    redisUsedMaxMb: Math.max(0, ...window.map((s) => s.redisUsedMb)),
    redisClientsMax: Math.max(0, ...window.map((s) => s.redisClients)),
    pgConnectionsMax: Math.max(0, ...window.map((s) => s.pgConnections)),
    pgDbFirstMb: window[0]?.pgDbMb ?? 0,
    pgDbLastMb: window.at(-1)?.pgDbMb ?? 0,
    pgMirrorLastMb: window.at(-1)?.pgMirrorMb ?? 0,
    containers: Object.fromEntries(
      containerNames.map((n) => {
        const xs = window.map((s) => s.containers[n]).filter((v) => v !== undefined);
        return [
          n,
          {
            cpuAvgPct: round1(avg(xs.map((v) => v.cpuPct))),
            cpuMaxPct: round1(Math.max(0, ...xs.map((v) => v.cpuPct))),
            memFirstMb: xs[0]?.memMb ?? 0,
            memMaxMb: Math.max(0, ...xs.map((v) => v.memMb)),
            memLastMb: xs.at(-1)?.memMb ?? 0,
          },
        ];
      }),
    ),
    disk: samples.filter((s) => s.diskMb !== undefined).map((s) => ({ t: s.t - epochMs, ...s.diskMb })),
  };
  const measuredMin = a.measureMs / 60_000;
  const report = {
    label: a.label,
    startedAt: new Date(epochMs).toISOString(),
    args: { ...a, databaseUrl: redactConnectionUrl(a.databaseUrl), redisUrl: redactConnectionUrl(a.redisUrl) },
    window: win,
    latency: merged,
    counters,
    statuses: sum((r) => r.statuses),
    failureCodes: sum((r) => r.failureCodes),
    rates: {
      measuredSendsPerSec: round1((counters.measuredSends ?? 0) / (a.measureMs / 1000)),
      eventsPerSec: round1((counters.eventsMeasured ?? 0) / (a.measureMs / 1000)),
      errorRatePct: round1(
        (100 * ((counters.sends5xx ?? 0) + (counters.sendNetErrors ?? 0) + (counters.runsFailed ?? 0) + (counters.runsTimedOut ?? 0))) /
          Math.max(1, counters.sends ?? 0),
      ),
      disconnectsPerMin: round1((counters.wsDisconnects ?? 0) / measuredMin),
    },
    resources,
    harness: {
      shards: results.map((r) => r.harness),
    },
    errors: results.flatMap((r) => r.errors).slice(0, 40),
    samples,
  };
  const out = JSON.stringify(report, null, 2);
  if (a.json !== null) await writeFile(resolve(process.cwd(), a.json), out);
  const { samples: _omit, ...brief } = report;
  console.log(JSON.stringify(brief, null, 2));
}

const invokedDirectly =
  process.argv[1] !== undefined && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly) {
  main().catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
