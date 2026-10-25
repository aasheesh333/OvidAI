import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { cpus, platform, totalmem } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createDb } from "@ovid/db";
import { Redis } from "ioredis";
import { runCapacityShard, type CapacityTarget, type ShardResult } from "./capacity.js";
import { parseMemMiB } from "./capacityCli.js";
import { LatencyHistogram } from "./hdr.js";
import {
  capacityStatement,
  evaluateSlo,
  parseReleaseProfile,
  type BuildIds,
  type EnvironmentEvidence,
  type MeasuredRun,
  type ProviderMode,
  type ReleaseProfile,
  type ReleaseStatus,
  type ResourceMeasurement,
  type SloEvaluation,
} from "./releaseMetrics.js";
import {
  runScenario,
  type LoadReport,
  type LoadTarget,
} from "./scenario.js";
import {
  FULL_THRESHOLDS,
  SMOKE_THRESHOLDS,
  checkThresholds,
} from "./thresholds.js";

export interface ReleaseGateArgs {
  profile: string;
  out: string;
  live: boolean;
}

export interface ReleaseGateDependencies {
  env: Record<string, string | undefined>;
  runScenario: typeof runScenario;
  runCapacityShard: typeof runCapacityShard;
  now: () => number;
  exec: (command: string, args: string[]) => Promise<string>;
}

interface ReleaseObservation {
  runId: string;
  profile: string;
  buildIds: BuildIds;
  providerMode: ProviderMode;
  evidence: Partial<MeasuredRun>;
}

interface ReleaseGateReport {
  schemaVersion: 1;
  generatedAt: string;
  profile: string | null;
  providerMode: ProviderMode;
  status: ReleaseStatus;
  buildIds: BuildIds;
  environment: EnvironmentEvidence | null;
  run: MeasuredRun | null;
  evaluation: SloEvaluation | null;
  failedGates: string[];
  unmeasuredGates: string[];
  errors: string[];
  capacityStatement: string;
}

interface ResolvedTarget extends LoadTarget, CapacityTarget {}

export interface ResourceSnapshots {
  cpu: ResourceMeasurement | null;
  memory: ResourceMeasurement | null;
  browserMemory: ResourceMeasurement | null;
  connections: { database: ResourceMeasurement | null; redis: ResourceMeasurement | null };
  notes: string[];
}

const BUILD_ENV = {
  gateway: "RELEASE_GATEWAY_BUILD_ID",
  worker: "RELEASE_WORKER_BUILD_ID",
  web: "RELEASE_WEB_BUILD_ID",
  android: "RELEASE_ANDROID_BUILD_ID",
  load: "RELEASE_LOAD_BUILD_ID",
} as const;

function defaultExec(command: string, args: string[]): Promise<string> {
  return new Promise((resolvePromise, reject) => {
    execFile(command, args, { encoding: "utf8", timeout: 20_000, maxBuffer: 4 << 20 }, (error, stdout) => {
      if (error) reject(error);
      else resolvePromise(stdout);
    });
  });
}

function dependencies(overrides: Partial<ReleaseGateDependencies>): ReleaseGateDependencies {
  return {
    env: process.env,
    runScenario,
    runCapacityShard,
    now: Date.now,
    exec: defaultExec,
    ...overrides,
  };
}

export function parseReleaseGateArgs(argv: string[]): ReleaseGateArgs {
  let profile: string | null = null;
  let out: string | null = null;
  let live = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]!;
    if (argument === "--live") {
      if (live) throw new Error("release gate: duplicate --live");
      live = true;
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`release gate: missing value for ${argument}`);
    if (argument === "--profile") {
      if (profile !== null) throw new Error("release gate: duplicate --profile");
      profile = value;
    } else if (argument === "--out") {
      if (out !== null) throw new Error("release gate: duplicate --out");
      out = value;
    } else {
      throw new Error(`release gate: unknown argument ${argument}`);
    }
    index += 1;
  }
  if (profile === null) throw new Error("release gate: --profile is required");
  if (out === null || out.trim() === "") throw new Error("release gate: --out is required");
  return { profile, out, live };
}

/** Record endpoints without credentials, query values, or fragments. */
export function safeConfigurationUrl(value: string | null | undefined): string | null {
  if (value === null || value === undefined || value.trim() === "") return null;
  try {
    const url = new URL(value);
    url.username = "";
    url.password = "";
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

function safeError(error: unknown): string {
  return (error instanceof Error ? error.message : String(error))
    .replace(/(?:postgres(?:ql)?|redis|https?):\/\/[^\s"']+/gi, "[REDACTED_URL]")
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [REDACTED]")
    .replace(/\b(?:sk|key|token)[-_][A-Za-z0-9_-]{8,}\b/gi, "[REDACTED]")
    .slice(0, 500);
}

function buildIds(env: Record<string, string | undefined>): BuildIds {
  return Object.fromEntries(
    Object.entries(BUILD_ENV).map(([key, name]) => [key, env[name]?.trim() || null]),
  ) as unknown as BuildIds;
}

function names(value: string | undefined): string[] {
  return [...new Set((value ?? "").split(",").map((entry) => entry.trim()).filter((entry) => entry !== ""))];
}

async function collectEnvironment(
  env: Record<string, string | undefined>,
  live: boolean,
  exec: ReleaseGateDependencies["exec"],
): Promise<{ evidence: EnvironmentEvidence; notes: string[] }> {
  const notes: string[] = [];
  const containerLimits: EnvironmentEvidence["containerLimits"] = {};
  for (const name of names(env.RELEASE_LOAD_CONTAINERS)) {
    try {
      const output = await exec("docker", ["inspect", "--format", "{{json .HostConfig}}", name]);
      const hostConfig = JSON.parse(output) as { NanoCPUs?: unknown; Memory?: unknown };
      const nano = typeof hostConfig.NanoCPUs === "number" ? hostConfig.NanoCPUs : 0;
      const memory = typeof hostConfig.Memory === "number" ? hostConfig.Memory : 0;
      containerLimits[name] = {
        cpuCores: nano > 0 ? nano / 1e9 : null,
        memoryMb: memory > 0 ? memory / 1048576 : null,
        source: "docker inspect HostConfig",
      };
    } catch (error) {
      containerLimits[name] = {
        cpuCores: null,
        memoryMb: null,
        source: "unmeasured: docker inspect failed",
      };
      notes.push(`container limits unmeasured for ${name}: ${safeError(error)}`);
    }
  }
  const providerName = live ? env.RELEASE_PROVIDER?.trim() || null : env.RELEASE_PROVIDER?.trim() || "mock-llm";
  return {
    evidence: {
      name: env.RELEASE_ENVIRONMENT?.trim() || "unmeasured",
      hardware: {
        cpuCores: cpus().length,
        memoryMb: totalmem() / 1048576,
        platform: platform(),
        source: "os.cpus/os.totalmem on the load-measurement host",
      },
      containerLimits,
      database: {
        url: safeConfigurationUrl(env.RELEASE_LOAD_DATABASE_URL),
        config: { poolMax: env.RELEASE_DATABASE_POOL_MAX?.trim() || null },
      },
      redis: {
        url: safeConfigurationUrl(env.RELEASE_LOAD_REDIS_Q_URL),
        config: { queuePrefix: env.RELEASE_LOAD_QUEUE_PREFIX?.trim() || null },
      },
      r2: {
        bucket: env.RELEASE_R2_BUCKET?.trim() || null,
        config: { endpoint: safeConfigurationUrl(env.RELEASE_R2_ENDPOINT) },
      },
      model: {
        name: env.RELEASE_MODEL?.trim() || null,
        config: { requestedModel: env.RELEASE_REQUESTED_MODEL?.trim() || null },
      },
      provider: {
        name: providerName,
        mode: live ? "live" : "mock",
        config: { catalog: env.RELEASE_PROVIDER_CATALOG?.trim() || null },
      },
    },
    notes,
  };
}

function object(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`release evidence: ${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requiredText(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`release evidence: ${label} is required`);
  return value;
}

function parseBuildIds(value: unknown): BuildIds {
  const input = object(value, "buildIds");
  const result = {} as BuildIds;
  for (const key of Object.keys(BUILD_ENV) as Array<keyof BuildIds>) {
    const build = input[key];
    if (build !== null && typeof build !== "string") throw new Error(`release evidence: buildIds.${key} is invalid`);
    result[key] = build;
  }
  return result;
}

async function readObservation(path: string): Promise<ReleaseObservation> {
  const input = object(JSON.parse(await readFile(resolve(process.cwd(), path), "utf8")), "root");
  const providerMode = requiredText(input.providerMode, "providerMode");
  if (providerMode !== "mock" && providerMode !== "live") throw new Error("release evidence: invalid providerMode");
  return {
    runId: requiredText(input.runId, "runId"),
    profile: requiredText(input.profile, "profile"),
    buildIds: parseBuildIds(input.buildIds),
    providerMode,
    evidence: object(input.evidence, "evidence") as Partial<MeasuredRun>,
  };
}

function sameBuilds(a: BuildIds, b: BuildIds): boolean {
  return (Object.keys(BUILD_ENV) as Array<keyof BuildIds>).every((key) => a[key] === b[key]);
}

function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  return `{${Object.entries(value as Record<string, unknown>)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, entry]) => `${JSON.stringify(key)}:${canonical(entry)}`).join(",")}}`;
}

type EvidenceIdentity = Pick<MeasuredRun,
  "runId" | "profile" | "buildIds" | "environment" | "series" | "kind" | "loadPoint">;

/** Envelope checks alone are insufficient: the embedded evidence must identify this exact run. */
function validateEmbeddedEvidence(
  evidence: Partial<MeasuredRun>,
  expected: EvidenceIdentity,
  mode: ProviderMode,
): void {
  if (evidence.runId !== expected.runId) {
    throw new Error("release evidence: embedded runId mismatch; stale evidence cannot be merged");
  }
  if (evidence.profile !== expected.profile) throw new Error("release evidence: embedded profile mismatch");
  if (evidence.buildIds === null || evidence.buildIds === undefined ||
    !sameBuilds(evidence.buildIds, expected.buildIds)) {
    throw new Error("release evidence: embedded build IDs mismatch");
  }
  if (evidence.environment === null || evidence.environment === undefined ||
    canonical(evidence.environment) !== canonical(expected.environment)) {
    throw new Error("release evidence: embedded environment mismatch");
  }
  if (evidence.series !== expected.series) throw new Error("release evidence: embedded series mismatch");
  if (evidence.kind !== expected.kind) throw new Error("release evidence: embedded kind mismatch");
  if (evidence.loadPoint !== expected.loadPoint) throw new Error("release evidence: embedded loadPoint mismatch");
  // A missing provider measurement belongs to evaluateSlo as UNMEASURED. A
  // present provider observation, however, must agree with both the
  // environment and invocation; the envelope can never lend it a mode.
  if ((evidence.provider !== null && evidence.provider !== undefined && evidence.provider.mode !== mode) ||
    evidence.environment.provider?.mode !== mode) {
    throw new Error(
      `release evidence: provider mode mismatch (provider=${evidence.provider?.mode ?? "missing"}, ` +
      `environment=${evidence.environment.provider?.mode ?? "missing"}, invocation=${mode})`,
    );
  }
}

function validateObservationAlignment(
  observation: ReleaseObservation,
  profile: ReleaseProfile,
  runId: string,
  mode: ProviderMode,
  builds: BuildIds | null,
): void {
  if (observation.runId !== runId) throw new Error("release evidence: runId mismatch; stale evidence cannot be merged");
  if (observation.profile !== profile.name) throw new Error("release evidence: profile mismatch");
  if (observation.providerMode !== mode) {
    throw new Error(`release evidence: mock/live mismatch (observation=${observation.providerMode}, invocation=${mode})`);
  }
  if (builds !== null && !sameBuilds(observation.buildIds, builds)) {
    throw new Error("release evidence: build IDs differ; reports cannot be merged");
  }
}

const SUPPLEMENT_FIELDS = [
  "queue", "firstToken", "cancellation", "lost", "duplicates", "integrity",
  "crossTenantFailures", "securityFailures", "availability", "crashFreeSessions", "anr",
  "browserMemory", "modelCost", "provider", "browser", "collab",
] as const;

export function supplement(
  base: MeasuredRun,
  evidence: Partial<MeasuredRun>,
  mode: ProviderMode,
): MeasuredRun {
  validateEmbeddedEvidence(evidence, base, mode);
  const result = { ...base, notes: [...base.notes] };
  for (const key of SUPPLEMENT_FIELDS) {
    const incoming = evidence[key];
    if (incoming === undefined) continue;
    const current = result[key];
    if (current === null || current === undefined) {
      (result as Record<string, unknown>)[key] = incoming;
    } else if (JSON.stringify(current) !== JSON.stringify(incoming)) {
      throw new Error(`release evidence: conflicting ${key}; separate runs cannot be merged`);
    }
  }
  return result;
}

function requireEnv(env: Record<string, string | undefined>, name: string): string {
  const value = env[name]?.trim();
  if (!value) throw new Error(`release gate preflight: ${name} is required`);
  return value;
}

function resolveTarget(profile: ReleaseProfile, env: Record<string, string | undefined>, live: boolean): ResolvedTarget {
  const config = profile.target!;
  const baseUrl = requireEnv(env, config.baseUrlEnv).replace(/\/+$/, "");
  const wsBase = requireEnv(env, config.wsBaseEnv).replace(/\/+$/, "");
  return {
    baseUrl,
    wsBase,
    databaseUrl: requireEnv(env, config.databaseUrlEnv),
    redisQUrl: requireEnv(env, config.redisQUrlEnv),
    mockLlmUrl: live ? "" : requireEnv(env, config.mockLlmUrlEnv),
    queuePrefix: requireEnv(env, config.queuePrefixEnv),
  };
}

function validateLoadPreflight(
  env: Record<string, string | undefined>,
  builds: BuildIds,
  live: boolean,
  profile: ReleaseProfile,
): string {
  const runId = requireEnv(env, "RELEASE_RUN_ID");
  for (const [key, variable] of Object.entries(BUILD_ENV)) {
    if (builds[key as keyof BuildIds] === null) throw new Error(`release gate preflight: ${variable} is required`);
  }
  requireEnv(env, "RELEASE_ENVIRONMENT");
  requireEnv(env, "RELEASE_R2_BUCKET");
  requireEnv(env, "RELEASE_MODEL");
  if (live) requireEnv(env, "RELEASE_PROVIDER");
  if (names(env.RELEASE_LOAD_CONTAINERS).length === 0) {
    throw new Error("release gate preflight: RELEASE_LOAD_CONTAINERS is required for container-limit evidence");
  }
  if (profile.kind === "browser" && names(env.RELEASE_BROWSER_CONTAINERS).length === 0) {
    throw new Error("release gate preflight: RELEASE_BROWSER_CONTAINERS is required for browser-memory evidence");
  }
  return runId;
}

function summarize(values: number[], unit: string, source: string): ResourceMeasurement | null {
  const valid = values.filter((value) => Number.isFinite(value) && value >= 0);
  if (valid.length === 0) return null;
  return {
    samples: valid.length,
    max: Math.max(...valid),
    mean: valid.reduce((sum, value) => sum + value, 0) / valid.length,
    unit,
    source,
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

async function startResourceSampler(
  target: ResolvedTarget,
  browserContainers: string[],
  exec: ReleaseGateDependencies["exec"],
): Promise<{ stop: () => Promise<ResourceSnapshots> }> {
  const values = {
    cpu: [] as number[],
    memory: [] as number[],
    browser: [] as number[],
    database: [] as number[],
    redis: [] as number[],
  };
  const notes: string[] = [];
  const note = (message: string): void => { if (notes.length < 50) notes.push(message); };
  const redis = new Redis(target.redisQUrl, { maxRetriesPerRequest: 1, lazyConnect: false });
  redis.on("error", () => {});
  const db = createDb(target.databaseUrl);
  let running = true;
  let previousCpu: { busy: number; total: number } | null = null;

  const sample = async (): Promise<void> => {
    try {
      const [stat, meminfo] = await Promise.all([
        readFile("/proc/stat", "utf8"),
        readFile("/proc/meminfo", "utf8"),
      ]);
      const parts = stat.split("\n")[0]!.trim().split(/\s+/).slice(1).map(Number);
      const idle = (parts[3] ?? 0) + (parts[4] ?? 0);
      const total = parts.reduce((sum, value) => sum + value, 0);
      const current = { busy: total - idle, total };
      if (previousCpu !== null && current.total > previousCpu.total) {
        values.cpu.push(100 * (current.busy - previousCpu.busy) / (current.total - previousCpu.total));
      }
      previousCpu = current;
      const totalKb = Number(/^MemTotal:\s+(\d+)/m.exec(meminfo)?.[1] ?? 0);
      const availableKb = Number(/^MemAvailable:\s+(\d+)/m.exec(meminfo)?.[1] ?? 0);
      if (totalKb > 0) values.memory.push((totalKb - availableKb) / 1024);
    } catch (error) {
      note(`host resource sample unmeasured: ${safeError(error)}`);
    }

    if (browserContainers.length > 0) {
      try {
        const output = await exec("docker", [
          "stats", "--no-stream", "--format", "{{.Name}}\t{{.MemUsage}}", ...browserContainers,
        ]);
        const found = new Map<string, number>();
        for (const line of output.split("\n")) {
          const [name, usage] = line.split("\t");
          if (name === undefined || usage === undefined) continue;
          const memory = parseMemMiB(usage);
          if (memory !== null) found.set(name, memory);
        }
        if (browserContainers.every((name) => found.has(name))) {
          values.browser.push(browserContainers.reduce((sum, name) => sum + found.get(name)!, 0));
        } else {
          note("browser memory sample skipped: not every configured browser container was observed");
        }
      } catch (error) {
        note(`browser memory sample unmeasured: ${safeError(error)}`);
      }
    }

    try {
      const info = await redis.info();
      const clients = Number(/^connected_clients:(\d+)$/m.exec(info)?.[1]);
      if (Number.isFinite(clients)) values.redis.push(clients);
    } catch (error) {
      note(`Redis connection sample unmeasured: ${safeError(error)}`);
    }
    try {
      const rows = await db.$client.unsafe(
        "SELECT count(*)::int AS n FROM pg_stat_activity WHERE datname = current_database()",
      ) as Array<{ n: number }>;
      const connections = Number(rows[0]?.n);
      if (Number.isFinite(connections)) values.database.push(connections);
    } catch (error) {
      note(`Postgres connection sample unmeasured: ${safeError(error)}`);
    }
  };

  const loop = (async () => {
    while (running) {
      await sample();
      if (running) await sleep(5_000);
    }
  })();

  return {
    stop: async () => {
      running = false;
      await loop;
      await redis.quit().catch(() => {});
      await db.$client.end({ timeout: 5 }).catch(() => {});
      return {
        cpu: summarize(values.cpu, "percent", "/proc/stat host CPU deltas"),
        memory: summarize(values.memory, "MiB", "/proc/meminfo MemTotal-MemAvailable"),
        browserMemory: summarize(values.browser, "MiB", `docker stats sum: ${browserContainers.join(",")}`),
        connections: {
          database: summarize(values.database, "connections", "pg_stat_activity for current database"),
          redis: summarize(values.redis, "connections", "Redis INFO connected_clients"),
        },
        notes,
      };
    },
  };
}

function emptyRun(
  profile: ReleaseProfile,
  runId: string,
  builds: BuildIds,
  environment: EnvironmentEvidence,
): MeasuredRun {
  return {
    runId,
    buildIds: builds,
    environment,
    profile: profile.name,
    series: profile.series,
    kind: profile.kind,
    loadPoint: profile.loadPoint,
    samples: 0,
    duration: 0,
    p50: null,
    p95: null,
    p99: null,
    latencySamples: 0,
    latencySource: null,
    queue: null,
    firstToken: null,
    completion: 0,
    failure: 0,
    cancellation: null,
    lost: null,
    duplicates: null,
    integrity: null,
    crossTenantFailures: null,
    securityFailures: null,
    availability: null,
    crashFreeSessions: null,
    anr: null,
    cpu: null,
    memory: null,
    browserMemory: null,
    connections: { database: null, redis: null },
    modelCost: null,
    provider: null,
    browser: null,
    collab: null,
    harness: { checked: false, thresholds: profile.thresholds, failures: [] },
    status: "unmeasured",
    notes: [],
  };
}

function applyResources(run: MeasuredRun, resources: ResourceSnapshots): void {
  run.cpu = resources.cpu;
  run.memory = resources.memory;
  run.browserMemory = resources.browserMemory;
  run.connections = resources.connections;
  run.notes.push(...resources.notes);
}

export function scenarioRun(
  profile: ReleaseProfile,
  report: LoadReport,
  base: MeasuredRun,
  resources: ResourceSnapshots,
): MeasuredRun {
  if (report.runId !== base.runId) {
    throw new Error(`release evidence: scenario runId mismatch (${report.runId ?? "missing"} != ${base.runId})`);
  }
  const run = { ...base, notes: [...(report.notes ?? [])] };
  run.duration = report.durationMs;
  run.completion = report.runsCompleted;
  run.failure = report.runsFailed + report.runsFailedUnattributed;
  // Terminal outcomes only: unfinished accepted runs are failures of evidence,
  // not silently removed from an availability claim or counted as completions.
  run.samples = run.completion + run.failure;
  run.p50 = report.eventDelivery.samples > 0 ? report.eventDelivery.p50Ms : null;
  run.p95 = report.eventDelivery.samples > 0 ? report.eventDelivery.p95Ms : null;
  run.p99 = report.eventDelivery.samples > 0 ? report.eventDelivery.p99Ms : null;
  run.latencySamples = report.eventDelivery.samples;
  run.latencySource = run.latencySamples > 0 ? "runScenario event append-ts to client receipt" : null;

  const integrityReadFailed = run.notes.some((note) => /ground truth read failed|mirror read failed/i.test(note));
  const integrityMeasured = run.latencySamples > 0 && !integrityReadFailed;
  if (integrityMeasured) {
    run.lost = report.integrity.lostEvents;
    run.duplicates = report.integrity.duplicateEvents;
    run.integrity = {
      samples: run.latencySamples,
      groundTruth: true,
      mirror: true,
      source: "runScenario diffIntegrity against Redis EventLog and Postgres session_event_mirror",
    };
  }

  const thresholds = profile.thresholds === "full" ? FULL_THRESHOLDS : SMOKE_THRESHOLDS;
  const failures = checkThresholds(report, thresholds, profile.scenario);
  if (report.admission.acceptedNotTerminal > 0 || report.runsStarted > run.completion + report.runsFailed) {
    failures.push("acceptedRunsNotTerminal");
  }
  if (run.notes.some((note) => /send failures: [1-9]|user \d+ failed/i.test(note))) {
    failures.push("scenarioUsersOrSends");
  }
  if (integrityReadFailed) failures.push("integrityGroundTruthRead");
  run.harness = {
    checked: true,
    thresholds: profile.thresholds as "smoke" | "full",
    failures: [...new Set(failures)],
  };
  applyResources(run, resources);
  return run;
}

function histogram(serialized: ShardResult["histograms"]["runTotal"]) {
  return LatencyHistogram.from(serialized).summary();
}

export function capacityRun(
  profile: ReleaseProfile,
  result: ShardResult,
  duration: number,
  base: MeasuredRun,
  resources: ResourceSnapshots,
): MeasuredRun {
  if (result.runId !== base.runId) {
    throw new Error(`release evidence: capacity runId mismatch (${result.runId ?? "missing"} != ${base.runId})`);
  }
  const run = { ...base, notes: [...result.errors] };
  run.duration = duration;
  run.loadPoint = result.connected;
  run.completion = result.counters.runsCompleted ?? 0;
  run.failure = result.counters.runsFailed ?? 0;
  run.samples = run.completion + run.failure;
  const primary = histogram(result.histograms.runTotal);
  run.latencySamples = primary.samples;
  run.latencySource = primary.samples > 0 ? "runCapacityShard measured send-to-run_completed" : null;
  run.p50 = primary.samples > 0 ? primary.p50 : null;
  run.p95 = primary.samples > 0 ? primary.p95 : null;
  run.p99 = primary.samples > 0 ? primary.p99 : null;
  const firstToken = histogram(result.histograms.firstToken);
  run.firstToken = firstToken.samples > 0 ? {
    p50: firstToken.p50,
    p95: firstToken.p95,
    p99: firstToken.p99,
    samples: firstToken.samples,
    source: "runCapacityShard send-to-first-message_delta; separate from queue delay",
  } : null;

  if (profile.kind === "browser") {
    // browserLiveUsersObserved is a cumulative set size, not a concurrency
    // high-water mark. Require a same-run observation for BrowserFacts instead
    // of turning transport counters into browser-capacity evidence.
    run.notes.push(
      `browser transport observations: attachOk=${result.counters.browserAttachOk ?? 0}, ` +
      `cumulativeLive=${result.counters.browserLiveUsersObserved ?? 0}, ` +
      `frames=${result.counters.browserFrames ?? 0}; concurrent viewer high-water mark requires same-run observation`,
    );
  }
  const failures: string[] = [];
  if (result.connected !== profile.capacity!.users) failures.push("capacity.connected");
  if ((result.counters.subscribeFailures ?? 0) > 0) failures.push("capacity.subscribeFailures");
  if ((result.counters.sends5xx ?? 0) > 0) failures.push("capacity.sends5xx");
  if ((result.counters.sends4xx ?? 0) > 0) failures.push("capacity.sends4xx");
  if ((result.counters.sendNetErrors ?? 0) > 0) failures.push("capacity.sendNetErrors");
  if ((result.counters.runsTimedOut ?? 0) > 0) failures.push("capacity.runsTimedOut");
  if (result.harness.loopDelayP99Ms > 50) failures.push("capacity.harnessLoopDelay");
  run.harness = { checked: true, thresholds: "external", failures };
  applyResources(run, resources);
  return run;
}

function renderValue(value: unknown): string {
  if (value === null || value === undefined) return "UNMEASURED";
  if (typeof value === "object") return `\`${JSON.stringify(value)}\``;
  return String(value);
}

export function renderReleaseGateReport(report: ReleaseGateReport): string {
  const run = report.run;
  const gateRows = report.evaluation?.gates.map((gate) =>
    `| ${gate.name} | ${gate.status} | ${renderValue(gate.actual)} | ${gate.expected} | ${renderValue(gate.source)} |`,
  ) ?? report.failedGates.map((gate) => `| ${gate} | failed | UNMEASURED | evidence must be complete | preflight |`);
  const latencyRow = (name: string, samples: unknown, p50: unknown, p95: unknown, p99: unknown, source: unknown): string =>
    `| ${name} | ${renderValue(samples)} | ${renderValue(p50)} | ${renderValue(p95)} | ${renderValue(p99)} | ${renderValue(source)} |`;
  return [
    `# Measured SLO / load report — ${report.profile ?? "invalid profile"}`,
    "",
    `- generatedAt: ${report.generatedAt}`,
    `- runId: ${run?.runId ?? "UNMEASURED"}`,
    `- status: **${report.status.toUpperCase()}**`,
    `- providerMode: ${report.providerMode}`,
    `- buildIds: \`${JSON.stringify(report.buildIds)}\``,
    `- environment: \`${JSON.stringify(report.environment)}\``,
    `- hardware/container limits and DB/Redis/R2/model/provider configuration are recorded in environment; null means unmeasured.`,
    `- samples: ${renderValue(run?.samples)}`,
    `- duration: ${renderValue(run?.duration)} ms`,
    `- loadPoint: ${renderValue(run?.loadPoint)}`,
    "",
    "## Latency (separate surfaces)",
    "",
    "| Surface | Samples | p50 ms | p95 ms | p99 ms | Source |",
    "|---|---:|---:|---:|---:|---|",
    latencyRow("primary", run?.latencySamples, run?.p50, run?.p95, run?.p99, run?.latencySource),
    latencyRow("queue", run?.queue?.samples, run?.queue?.p50, run?.queue?.p95, run?.queue?.p99, run?.queue?.source),
    latencyRow("firstToken", run?.firstToken?.samples, run?.firstToken?.p50, run?.firstToken?.p95, run?.firstToken?.p99, run?.firstToken?.source),
    "",
    "## Outcomes, resources, and actual cost",
    "",
    `- completion/failure/cancellation: ${renderValue(run?.completion)} / ${renderValue(run?.failure)} / ${renderValue(run?.cancellation)}`,
    `- lost/duplicates/integrity: ${renderValue(run?.lost)} / ${renderValue(run?.duplicates)} / ${renderValue(run?.integrity)}`,
    `- availability/crashFreeSessions/ANR: ${renderValue(run?.availability)} / ${renderValue(run?.crashFreeSessions)} / ${renderValue(run?.anr)}`,
    `- crossTenant/security failures: ${renderValue(run?.crossTenantFailures)} / ${renderValue(run?.securityFailures)}`,
    `- cpu/memory/connections: ${renderValue(run?.cpu)} / ${renderValue(run?.memory)} / ${renderValue(run?.connections)}`,
    `- browserMemory/browser: ${renderValue(run?.browserMemory)} / ${renderValue(run?.browser)}`,
    `- collab: ${renderValue(run?.collab)}`,
    `- provider: ${renderValue(run?.provider)}`,
    `- modelCost: ${renderValue(run?.modelCost)}`,
    `- effective run_failed: ${renderValue(report.evaluation?.runFailedPct)}% over ${renderValue(report.evaluation?.effectiveSamples)} samples`,
    "",
    "## Gates",
    "",
    "| Gate | Result | Actual | Required | Source |",
    "|---|---|---:|---|---|",
    ...gateRows,
    "",
    `- failedGates: \`${JSON.stringify(report.failedGates)}\``,
    `- unmeasuredGates: \`${JSON.stringify(report.unmeasuredGates)}\``,
    `- errors: ${report.errors.length === 0 ? "none" : report.errors.map(safeError).join("; ")}`,
    `- notes: ${run === null || run.notes.length === 0 ? "none" : run.notes.map(safeError).join("; ")}`,
    "",
    "## Publishable statement",
    "",
    report.capacityStatement,
    "",
  ].join("\n");
}

async function writeReport(prefix: string, report: ReleaseGateReport): Promise<void> {
  const path = resolve(process.cwd(), prefix);
  await mkdir(dirname(path), { recursive: true });
  await Promise.all([
    writeFile(`${path}.json`, `${JSON.stringify(report, null, 2)}\n`, "utf8"),
    writeFile(`${path}.md`, renderReleaseGateReport(report), "utf8"),
  ]);
}

function reportFor(
  generatedAt: string,
  profile: ReleaseProfile | null,
  mode: ProviderMode,
  run: MeasuredRun | null,
  evaluation: SloEvaluation | null,
  failedGates: string[],
  errors: string[],
  fallbackBuilds: BuildIds,
  fallbackEnvironment: EnvironmentEvidence | null,
): ReleaseGateReport {
  const status: ReleaseStatus = evaluation?.status ?? "fail";
  const conditions = run?.environment.name ?? fallbackEnvironment?.name ?? "unmeasured environment";
  // Never serialize an artifact-supplied status: every output path uses the
  // computed evaluation, or fail when evaluation/reporting could not complete.
  const normalizedRun = run === null ? null : { ...run, status };
  return {
    schemaVersion: 1,
    generatedAt,
    profile: profile?.name ?? null,
    providerMode: mode,
    status,
    buildIds: normalizedRun?.buildIds ?? fallbackBuilds,
    environment: normalizedRun?.environment ?? fallbackEnvironment,
    run: normalizedRun,
    evaluation,
    failedGates: evaluation === null ? failedGates : evaluation.failedGates,
    unmeasuredGates: evaluation?.unmeasuredGates ?? [],
    errors,
    capacityStatement: normalizedRun === null || evaluation?.status !== "pass"
      ? `No passing measured load point under ${conditions}; REAL LOAD RUNS PENDING.`
      : capacityStatement([normalizedRun], conditions),
  };
}

/**
 * Run an authorized profile against explicitly supplied endpoints. No endpoint
 * defaults to production. Every nonzero path still attempts JSON + Markdown.
 */
export async function runReleaseGateCli(
  argv: string[],
  overrides: Partial<ReleaseGateDependencies> = {},
): Promise<number> {
  const deps = dependencies(overrides);
  let options: ReleaseGateArgs | null = null;
  let profile: ReleaseProfile | null = null;
  let mode: ProviderMode = "mock";
  let stage = "preflight";
  let activeRun: MeasuredRun | null = null;
  let environment: EnvironmentEvidence | null = null;
  const generatedAt = new Date(deps.now()).toISOString();

  try {
    options = parseReleaseGateArgs(argv);
    mode = options.live ? "live" : "mock";
    profile = parseReleaseProfile(JSON.parse(await readFile(resolve(process.cwd(), options.profile), "utf8")));
    const observationPath = deps.env[profile.observationEnv]?.trim() || null;
    const builds = buildIds(deps.env);

    if (profile.runner === "observed") {
      stage = "evidence";
      if (observationPath === null) throw new Error(`release evidence: ${profile.observationEnv} is required for observed runner`);
      const observation = await readObservation(observationPath);
      validateObservationAlignment(observation, profile, observation.runId, mode, null);
      const evidence = observation.evidence as MeasuredRun;
      validateEmbeddedEvidence(evidence, {
        runId: observation.runId,
        profile: profile.name,
        buildIds: observation.buildIds,
        environment: evidence.environment,
        series: profile.series,
        kind: profile.kind,
        loadPoint: profile.loadPoint,
      }, mode);
      activeRun = {
        ...evidence,
        runId: observation.runId,
        profile: profile.name,
        buildIds: observation.buildIds,
        status: "unmeasured",
        notes: [...(evidence.notes ?? []), "observed runner: no generic HTTP throughput was substituted for specialized evidence"],
      };
      environment = activeRun.environment;
    } else {
      const runId = validateLoadPreflight(deps.env, builds, options.live, profile);
      stage = "evidence";
      let observation: ReleaseObservation | null = null;
      if (observationPath !== null) {
        observation = await readObservation(observationPath);
        validateObservationAlignment(observation, profile, runId, mode, builds);
      }
      stage = "preflight";
      const target = resolveTarget(profile, deps.env, options.live);
      const collected = await collectEnvironment(deps.env, options.live, deps.exec);
      environment = collected.evidence;
      const base = emptyRun(profile, runId, builds, environment);
      base.notes.push(...collected.notes);
      if (observation !== null) validateEmbeddedEvidence(observation.evidence, base, mode);
      const sampler = await startResourceSampler(target, names(deps.env.RELEASE_BROWSER_CONTAINERS), deps.exec);
      try {
        stage = "load";
        if (profile.runner === "scenario") {
          const report = await deps.runScenario(profile.scenario!, target, { runId });
          const resources = await sampler.stop();
          activeRun = scenarioRun(profile, report, base, resources);
        } else {
          const started = Date.now();
          const result = await deps.runCapacityShard({
            shard: 0,
            userOffset: 0,
            runTag: runId,
            epochMs: started + 1_000,
            profile: profile.capacity!,
            target,
          });
          const resources = await sampler.stop();
          activeRun = capacityRun(profile, result, Date.now() - started, base, resources);
        }
      } finally {
        // stop is idempotent for the Redis/DB teardown only when called once;
        // this second call is avoided by tracking whether activeRun was built.
        if (activeRun === null) await sampler.stop();
      }
      if (observation !== null) activeRun = supplement(activeRun, observation.evidence, mode);
    }

    stage = "evaluation";
    const evaluation = evaluateSlo(activeRun);
    activeRun.status = evaluation.status;
    const report = reportFor(
      generatedAt, profile, mode, activeRun, evaluation, [], [], buildIds(deps.env), environment,
    );
    await writeReport(options.out, report);
    console.log(`release gate: ${report.status}; reports: ${options.out}.json, ${options.out}.md`);
    return evaluation.status === "pass" ? 0 : 1;
  } catch (error) {
    const failedGate = stage === "evidence" ? "evidence" : stage === "evaluation" ? "evaluation" : stage === "load" ? "load" : "preflight";
    try {
      if (environment === null) environment = (await collectEnvironment(deps.env, mode === "live", deps.exec)).evidence;
      const report = reportFor(
        generatedAt,
        profile,
        mode,
        activeRun,
        null,
        [failedGate],
        [safeError(error)],
        buildIds(deps.env),
        environment,
      );
      const fallbackOut = options?.out ?? (() => {
        const index = argv.indexOf("--out");
        return index >= 0 ? argv[index + 1] : undefined;
      })();
      if (fallbackOut === undefined) {
        console.error(safeError(error));
        return 2;
      }
      await writeReport(fallbackOut, report);
      console.error(`release gate ${failedGate}: ${safeError(error)}; failure reports written`);
      return 2;
    } catch (writeFailure) {
      console.error(`${safeError(error)}; additionally could not write failure report: ${safeError(writeFailure)}`);
      return 2;
    }
  }
}

const invokedDirectly = process.argv[1] !== undefined &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly) {
  runReleaseGateCli(process.argv.slice(2)).then((code) => {
    process.exitCode = code;
  }).catch((error: unknown) => {
    console.error(safeError(error));
    process.exitCode = 2;
  });
}
