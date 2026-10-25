import type { CapacityProfile } from "./capacity.js";
import type { LoadProfile } from "./scenario.js";

/** A release status is computed from measurements; an input status is never trusted. */
export type ReleaseStatus = "pass" | "fail" | "unmeasured";
export type ProviderMode = "mock" | "live";
export type ReleaseKind = "agent" | "collab" | "browser" | "provider";

export interface BuildIds {
  gateway: string | null;
  worker: string | null;
  web: string | null;
  android: string | null;
  load: string | null;
}

export interface DependencyConfiguration {
  url: string | null;
  config: Record<string, string | number | boolean | null>;
}

export interface EnvironmentEvidence {
  name: string;
  hardware: {
    cpuCores: number | null;
    memoryMb: number | null;
    platform: string;
    source: string;
  };
  containerLimits: Record<string, {
    cpuCores: number | null;
    memoryMb: number | null;
    source: string;
  }>;
  database: DependencyConfiguration;
  redis: DependencyConfiguration;
  r2: {
    bucket: string | null;
    config: Record<string, string | number | boolean | null>;
  };
  model: {
    name: string | null;
    config: Record<string, string | number | boolean | null>;
  };
  provider: {
    name: string | null;
    mode: ProviderMode;
    config: Record<string, string | number | boolean | null>;
  };
}

/** `samples > 0` is required before a numeric value can be a passing fact. */
export interface ResourceMeasurement {
  samples: number;
  max: number;
  mean: number | null;
  unit: string;
  source: string;
}

export interface RatioMeasurement {
  /** Percent in [0, 100], not a fraction in [0, 1]. */
  percent: number;
  samples: number;
  source: string;
}

export interface CountMeasurement {
  count: number;
  samples: number;
  source: string;
}

export interface PercentileMeasurement {
  p50: number;
  p95: number;
  p99: number;
  samples: number;
  source: string;
}

export interface ActualModelCost {
  amount: number;
  currency: "USD";
  samples: number;
  /** Actual metering sources only (for example `litellm` or `provider`). */
  sources: string[];
}

export interface ProviderFacts {
  mode: ProviderMode;
  requestSamples: number;
  /** Required only for a live run; a mock run can never populate this. */
  liveRequestSamples: number | null;
  rateLimitObservations: number | null;
  /** Same-run facts for every provider; aggregate counters alone are insufficient. */
  perProvider: Record<string, { requestSamples: number; rateLimitObservations: number }> | null;
  lazyConnections: (ResourceMeasurement & { limit: number }) | null;
  schemaBudget: {
    samples: number;
    maxBytes: number;
    budgetBytes: number;
    violations: number;
    source: string;
  } | null;
  oauthRefreshStorm: {
    samples: number;
    attempts: number;
    unexpectedFailures: number;
    duplicateRefreshes: number;
    source: string;
  } | null;
}

export interface BrowserFacts {
  viewerSamples: number;
  maxConcurrentViewers: number;
  frameSamples: number;
  source: string;
}

export interface CollabFacts {
  members: number;
  ownerIncluded: boolean;
  joinSamples: number;
  competingJoinSamples: number;
  turnSamples: number;
  competingTurnSamples: number;
  longPollSamples: number;
  maxSenderLeases: number;
  hostAccountingSamples: number;
  senderAccountingSamples: number;
  unexpectedFailures: number;
  source: string;
}

export interface MeasuredRun {
  runId: string;
  buildIds: BuildIds;
  environment: EnvironmentEvidence;
  profile: string;
  series: string;
  kind: ReleaseKind;
  /** The actual exercised point, not a desired or inferred point. */
  loadPoint: number;
  samples: number;
  /** Actual measured wall-clock duration in milliseconds. */
  duration: number;
  /** Primary latency, with its kind identified by latencySource. */
  p50: number | null;
  p95: number | null;
  p99: number | null;
  latencySamples: number;
  latencySource: string | null;
  /** Queue delay is deliberately not send→202 or first-token latency. */
  queue: PercentileMeasurement | null;
  firstToken: PercentileMeasurement | null;
  completion: number;
  /** All observed run_failed records, including classified cancellations. */
  failure: number;
  /** Only user/injected subsets are excluded from the reliability rate. */
  cancellation: { user: number; injected: number; other: number } | null;
  lost: number | null;
  duplicates: number | null;
  integrity: {
    samples: number;
    groundTruth: boolean;
    mirror: boolean;
    source: string;
  } | null;
  crossTenantFailures: CountMeasurement | null;
  securityFailures: CountMeasurement | null;
  availability: RatioMeasurement | null;
  crashFreeSessions: RatioMeasurement | null;
  anr: RatioMeasurement | null;
  cpu: ResourceMeasurement | null;
  memory: ResourceMeasurement | null;
  /** Separate from gateway/host memory; mandatory for browser viewer runs. */
  browserMemory: ResourceMeasurement | null;
  connections: {
    database: ResourceMeasurement | null;
    redis: ResourceMeasurement | null;
  };
  modelCost: ActualModelCost | null;
  provider: ProviderFacts | null;
  browser: BrowserFacts | null;
  collab: CollabFacts | null;
  harness: {
    checked: boolean;
    thresholds: "smoke" | "full" | "external";
    failures: string[];
  };
  status: ReleaseStatus;
  notes: string[];
}

export type SloGateStatus = "passed" | "failed" | "unmeasured";

export interface SloGate {
  name: string;
  status: SloGateStatus;
  actual: number | null;
  expected: string;
  source: string | null;
}

export interface SloEvaluation {
  status: ReleaseStatus;
  gates: SloGate[];
  failedGates: string[];
  unmeasuredGates: string[];
  effectiveSamples: number | null;
  runFailedPct: number | null;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function hasSamples(value: { samples: number }): boolean {
  return isNonNegativeInteger(value.samples) && value.samples > 0;
}

function validPercentiles(value: PercentileMeasurement): boolean {
  return hasSamples(value) &&
    [value.p50, value.p95, value.p99].every((sample) => isFiniteNumber(sample) && sample >= 0);
}

function ratioGate(
  name: string,
  measurement: RatioMeasurement | null,
  minimum: number | null,
  maximum: number | null,
): SloGate {
  const expected = minimum !== null ? `>= ${minimum}%` : `<= ${maximum}%`;
  if (measurement === null || !hasSamples(measurement) || !isFiniteNumber(measurement.percent)) {
    return { name, status: "unmeasured", actual: null, expected, source: measurement?.source ?? null };
  }
  if (measurement.percent < 0 || measurement.percent > 100) {
    throw new Error(`invalid measurements: ${name} percent is outside [0, 100]`);
  }
  const passed = minimum !== null ? measurement.percent >= minimum : measurement.percent <= maximum!;
  return {
    name,
    status: passed ? "passed" : "failed",
    actual: measurement.percent,
    expected,
    source: measurement.source,
  };
}

function countGate(
  name: string,
  measurement: CountMeasurement | null,
): SloGate {
  if (measurement !== null && isFiniteNumber(measurement.count) && measurement.count > 0) {
    return { name, status: "failed", actual: measurement.count, expected: "= 0", source: measurement.source };
  }
  if (measurement === null || !hasSamples(measurement) || !isNonNegativeInteger(measurement.count)) {
    return { name, status: "unmeasured", actual: null, expected: "= 0", source: measurement?.source ?? null };
  }
  return { name, status: "passed", actual: measurement.count, expected: "= 0", source: measurement.source };
}

function resourceGate(name: string, measurement: ResourceMeasurement | null): SloGate {
  if (
    measurement === null ||
    !hasSamples(measurement) ||
    !isFiniteNumber(measurement.max) ||
    measurement.max < 0 ||
    measurement.source.trim() === ""
  ) {
    return {
      name,
      status: "unmeasured",
      actual: null,
      expected: "measured with samples > 0",
      source: measurement?.source ?? null,
    };
  }
  return {
    name,
    status: "passed",
    actual: measurement.max,
    expected: "measured with samples > 0",
    source: measurement.source,
  };
}

/**
 * Evaluate the release objectives without inferring absent facts. Threshold
 * equality is intentional: 99.5% availability/crash-free and 0.5% ANR pass.
 */
export function evaluateSlo(run: MeasuredRun): SloEvaluation {
  if (!isNonNegativeInteger(run.samples) || run.samples === 0) {
    throw new Error("missing measurements: samples must be a positive integer");
  }
  if (!isFiniteNumber(run.duration) || run.duration <= 0) {
    throw new Error("invalid measurements: duration must be positive");
  }
  if (!isNonNegativeInteger(run.completion) || !isNonNegativeInteger(run.failure)) {
    throw new Error("invalid measurements: completion/failure must be non-negative integers");
  }
  if (run.completion + run.failure > run.samples) {
    throw new Error("invalid measurements: completion + failure exceeds samples");
  }

  const gates: SloGate[] = [];
  const buildsComplete = (["gateway", "worker", "web", "android", "load"] as const)
    .every((key) => typeof run.buildIds?.[key] === "string" && run.buildIds[key]!.trim() !== "");
  gates.push({
    name: "buildIds",
    status: buildsComplete ? "passed" : "unmeasured",
    actual: null,
    expected: "gateway/worker/web/android/load build IDs",
    source: "build manifest",
  });

  const env = run.environment;
  const environmentComplete = env !== undefined && env.name.trim() !== "" &&
    isFiniteNumber(env.hardware?.cpuCores) && (env.hardware.cpuCores ?? 0) > 0 &&
    isFiniteNumber(env.hardware?.memoryMb) && (env.hardware.memoryMb ?? 0) > 0 &&
    Object.keys(env.containerLimits ?? {}).length > 0 &&
    Object.values(env.containerLimits ?? {}).every((limit) =>
      isFiniteNumber(limit.cpuCores) && (limit.cpuCores ?? 0) > 0 &&
      isFiniteNumber(limit.memoryMb) && (limit.memoryMb ?? 0) > 0) &&
    typeof env.database?.url === "string" && env.database.url !== "" &&
    typeof env.redis?.url === "string" && env.redis.url !== "" &&
    typeof env.r2?.bucket === "string" && env.r2.bucket !== "" &&
    typeof env.model?.name === "string" && env.model.name !== "" &&
    typeof env.provider?.name === "string" && env.provider.name !== "";
  gates.push({
    name: "environment",
    status: environmentComplete ? "passed" : "unmeasured",
    actual: null,
    expected: "hardware, limits, DB/Redis/R2/model/provider configuration",
    source: env?.hardware?.source ?? null,
  });

  const primaryLatencyValid = isNonNegativeInteger(run.latencySamples) && run.latencySamples > 0 &&
    [run.p50, run.p95, run.p99].every((value) => isFiniteNumber(value) && value >= 0) &&
    typeof run.latencySource === "string" && run.latencySource !== "";
  gates.push({
    name: "latency",
    status: primaryLatencyValid ? "passed" : "unmeasured",
    actual: primaryLatencyValid ? run.p95 : null,
    expected: "measured p50/p95/p99; no baseline target invented",
    source: run.latencySource,
  });
  for (const [name, measurement] of [["queueLatency", run.queue], ["firstTokenLatency", run.firstToken]] as const) {
    const valid = measurement !== null && validPercentiles(measurement);
    gates.push({
      name,
      status: valid ? "passed" : "unmeasured",
      actual: valid ? measurement.p95 : null,
      expected: "separate measured p50/p95/p99; no baseline target invented",
      source: measurement?.source ?? null,
    });
  }

  gates.push(ratioGate("availability", run.availability, 99.5, null));
  gates.push(ratioGate("crashFreeSessions", run.crashFreeSessions, 99.5, null));
  gates.push(ratioGate("anr", run.anr, null, 0.5));

  const integrityFailed = (run.lost ?? 0) > 0 || (run.duplicates ?? 0) > 0;
  const integrityMeasured = run.integrity !== null && hasSamples(run.integrity) &&
    run.integrity.groundTruth && run.integrity.mirror &&
    isNonNegativeInteger(run.lost) && isNonNegativeInteger(run.duplicates);
  gates.push({
    name: "integrity",
    status: integrityFailed ? "failed" : integrityMeasured ? "passed" : "unmeasured",
    actual: integrityFailed ? (run.lost ?? 0) + (run.duplicates ?? 0) : integrityMeasured ? 0 : null,
    expected: "zero lost/duplicate events with real ground-truth + mirror diff",
    source: run.integrity?.source ?? null,
  });
  gates.push(countGate("crossTenant", run.crossTenantFailures));
  gates.push(countGate("security", run.securityFailures));

  let excluded = 0;
  if (run.cancellation !== null) {
    const { user, injected, other } = run.cancellation;
    if (![user, injected, other].every(isNonNegativeInteger)) {
      throw new Error("invalid cancellation measurements: counts must be non-negative integers");
    }
    if (user + injected + other > run.failure) {
      throw new Error("invalid cancellation measurements: classified cancellations exceed failure count");
    }
    excluded = user + injected;
  }
  const effectiveSamples = run.samples - excluded;
  const effectiveFailures = run.failure - excluded;
  const runFailedPct = effectiveSamples > 0 ? (effectiveFailures / effectiveSamples) * 100 : null;
  gates.push({
    name: "runFailed",
    status: runFailedPct === null ? "unmeasured" : runFailedPct <= 1 ? "passed" : "failed",
    actual: runFailedPct,
    expected: "<= 1% after excluding actual injected/user cancellations",
    source: run.cancellation === null ? "unclassified failures conservatively retained" : "classified run_failed records",
  });

  gates.push(resourceGate("cpu", run.cpu));
  gates.push(resourceGate("memory", run.memory));
  gates.push(resourceGate("databaseConnections", run.connections?.database ?? null));
  gates.push(resourceGate("redisConnections", run.connections?.redis ?? null));

  const costMeasured = run.modelCost !== null && hasSamples(run.modelCost) &&
    isFiniteNumber(run.modelCost.amount) && run.modelCost.amount >= 0 &&
    run.modelCost.currency === "USD" && run.modelCost.sources.length > 0 &&
    run.modelCost.sources.every((source) => source.trim() !== "" && !/estimate|reserved/i.test(source));
  gates.push({
    name: "modelCost",
    status: costMeasured ? "passed" : "unmeasured",
    actual: costMeasured ? run.modelCost!.amount : null,
    expected: "actual metered USD cost with samples > 0",
    source: run.modelCost?.sources.join(",") ?? null,
  });

  const provider = run.provider;
  const providerMeasured = provider !== null && isNonNegativeInteger(provider.requestSamples) &&
    provider.requestSamples > 0;
  gates.push({
    name: "provider",
    status: providerMeasured ? "passed" : "unmeasured",
    actual: providerMeasured ? provider.requestSamples : null,
    expected: "actual provider requests in the same run",
    source: provider?.mode ?? null,
  });
  const providerModeMatches = provider !== null && provider.mode === env?.provider?.mode;
  gates.push({
    name: "providerMode",
    status: provider === null ? "unmeasured" : providerModeMatches ? "passed" : "failed",
    actual: null,
    expected: "run and environment use the same mock/live mode",
    source: provider?.mode ?? null,
  });
  if (provider?.mode === "live" || env?.provider?.mode === "live") {
    const liveMeasured = provider?.mode === "live" && env?.provider?.mode === "live" &&
      isNonNegativeInteger(provider.liveRequestSamples) && (provider.liveRequestSamples ?? 0) > 0;
    gates.push({
      name: "liveProvider",
      status: liveMeasured ? "passed" : "unmeasured",
      actual: liveMeasured ? provider.liveRequestSamples : null,
      expected: "actual live-provider responses; mock evidence is not live evidence",
      source: provider?.mode ?? null,
    });
  }

  gates.push({
    name: "harnessThresholds",
    status: !run.harness?.checked ? "unmeasured" : run.harness.failures.length > 0 ? "failed" : "passed",
    actual: run.harness?.failures.length ?? null,
    expected: "existing scenario/capacity thresholds checked with zero failures",
    source: run.harness?.thresholds ?? null,
  });

  if (run.kind === "browser") {
    gates.push(resourceGate("browserMemory", run.browserMemory));
    const browser = run.browser;
    const measured = browser !== null && isNonNegativeInteger(browser.viewerSamples) &&
      browser.viewerSamples > 0 && isNonNegativeInteger(browser.frameSamples) && browser.frameSamples > 0 &&
      isNonNegativeInteger(browser.maxConcurrentViewers);
    gates.push({
      name: "browserViewers",
      status: !measured ? "unmeasured" : browser.maxConcurrentViewers >= run.loadPoint ? "passed" : "failed",
      actual: measured ? browser.maxConcurrentViewers : null,
      expected: `actual frames/viewers at load point ${run.loadPoint}`,
      source: browser?.source ?? null,
    });
  }

  if (run.kind === "collab") {
    const collab = run.collab;
    const measured = collab !== null && [collab.joinSamples, collab.competingJoinSamples,
      collab.turnSamples, collab.competingTurnSamples, collab.longPollSamples,
      collab.hostAccountingSamples, collab.senderAccountingSamples].every((value) => isNonNegativeInteger(value) && value > 0) &&
      typeof collab.ownerIncluded === "boolean" &&
      isNonNegativeInteger(collab.members) && isNonNegativeInteger(collab.maxSenderLeases) &&
      isNonNegativeInteger(collab.unexpectedFailures);
    const passed = measured && collab.members === run.loadPoint && collab.ownerIncluded &&
      collab.maxSenderLeases === 1 && collab.unexpectedFailures === 0;
    gates.push({
      name: "collabScenario",
      status: !measured ? "unmeasured" : passed ? "passed" : "failed",
      actual: measured ? collab.members : null,
      expected: `${run.loadPoint} members incl. owner, joins/turns/long polls, one sender lease, host+sender accounting`,
      source: collab?.source ?? null,
    });
  }

  if (run.kind === "provider") {
    const lazy = provider?.lazyConnections ?? null;
    const lazyGate = resourceGate("lazyConnections", lazy);
    if (lazy !== null && lazyGate.status === "passed" &&
      (!isFiniteNumber(lazy.limit) || lazy.max > lazy.limit)) {
      lazyGate.status = "failed";
      lazyGate.expected = `measured and <= ${lazy.limit} lazy connections`;
    }
    gates.push(lazyGate);

    const schema = provider?.schemaBudget ?? null;
    const schemaMeasured = schema !== null && isNonNegativeInteger(schema.samples) && schema.samples > 0 &&
      isFiniteNumber(schema.maxBytes) && schema.maxBytes >= 0 &&
      isFiniteNumber(schema.budgetBytes) && schema.budgetBytes > 0 &&
      isNonNegativeInteger(schema.violations);
    gates.push({
      name: "schemaBudget",
      status: !schemaMeasured ? "unmeasured" : schema.maxBytes <= schema.budgetBytes && schema.violations === 0 ? "passed" : "failed",
      actual: schemaMeasured ? schema.maxBytes : null,
      expected: schema === null ? "measured serialized-schema budget" : `<= ${schema.budgetBytes} bytes, zero violations`,
      source: schema?.source ?? null,
    });

    const oauth = provider?.oauthRefreshStorm ?? null;
    const oauthMeasured = oauth !== null && isNonNegativeInteger(oauth.samples) && oauth.samples > 0 &&
      isNonNegativeInteger(oauth.attempts) && oauth.attempts > 0 &&
      isNonNegativeInteger(oauth.unexpectedFailures) && isNonNegativeInteger(oauth.duplicateRefreshes);
    gates.push({
      name: "oauthRefreshStorm",
      status: !oauthMeasured ? "unmeasured" : oauth.unexpectedFailures === 0 && oauth.duplicateRefreshes === 0 ? "passed" : "failed",
      actual: oauthMeasured ? oauth.attempts : null,
      expected: "actual refresh storm, zero duplicate refreshes/unexpected failures",
      source: oauth?.source ?? null,
    });

    const aggregateRatesMeasured = provider !== null &&
      isNonNegativeInteger(provider.requestSamples) && provider.requestSamples > 0 &&
      isNonNegativeInteger(provider.rateLimitObservations) && (provider.rateLimitObservations ?? 0) > 0;
    const perProviderEntries = provider?.perProvider !== null && provider?.perProvider !== undefined
      ? Object.entries(provider.perProvider)
      : [];
    const perProviderMeasured = perProviderEntries.length > 0 && perProviderEntries.every(([name, facts]) =>
      name.trim() !== "" && isNonNegativeInteger(facts.requestSamples) && facts.requestSamples > 0 &&
      isNonNegativeInteger(facts.rateLimitObservations) && facts.rateLimitObservations > 0);
    const totalsMatch = aggregateRatesMeasured && perProviderMeasured &&
      perProviderEntries.reduce((sum, [, facts]) => sum + facts.requestSamples, 0) === provider!.requestSamples &&
      perProviderEntries.reduce((sum, [, facts]) => sum + facts.rateLimitObservations, 0) === provider!.rateLimitObservations!;
    gates.push({
      name: "providerRateLimits",
      status: !aggregateRatesMeasured || !perProviderMeasured ? "unmeasured" : totalsMatch ? "passed" : "failed",
      actual: aggregateRatesMeasured ? provider.rateLimitObservations : null,
      expected: "actual request/rate-limit observations for every provider, reconciled to aggregates",
      source: provider?.mode ?? null,
    });
  }

  const failedGates = gates.filter((gate) => gate.status === "failed").map((gate) => gate.name);
  const unmeasuredGates = gates.filter((gate) => gate.status === "unmeasured").map((gate) => gate.name);
  return {
    status: failedGates.length > 0 ? "fail" : unmeasuredGates.length > 0 ? "unmeasured" : "pass",
    gates,
    failedGates,
    unmeasuredGates,
    effectiveSamples: effectiveSamples > 0 ? effectiveSamples : null,
    runFailedPct,
  };
}

function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  return `{${Object.entries(value as Record<string, unknown>)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, entry]) => `${JSON.stringify(key)}:${canonical(entry)}`).join(",")}}`;
}

/** Return the contiguous passing prefix, never a later point beyond a failure. */
export function highestPassing(runs: MeasuredRun[]): number | null {
  if (runs.length === 0) return null;
  const modes = new Set(runs.map((run) => run.provider?.mode ?? run.environment?.provider?.mode ?? "missing"));
  if (modes.size > 1) throw new Error("mock/live provider reports cannot be merged");
  const series = new Set(runs.map((run) => run.series));
  const kinds = new Set(runs.map((run) => run.kind));
  if (series.size > 1 || kinds.size > 1) throw new Error("different kind/series evidence cannot be merged");
  const buildSets = new Set(runs.map((run) => canonical(run.buildIds)));
  if (buildSets.size > 1) throw new Error("different build IDs cannot be merged");
  const environments = new Set(runs.map((run) => canonical(run.environment)));
  if (environments.size > 1) throw new Error("different environments cannot be merged");

  const sorted = [...runs].sort((a, b) => a.loadPoint - b.loadPoint);
  const points = new Set<number>();
  let highest: number | null = null;
  for (const run of sorted) {
    if (!isFiniteNumber(run.loadPoint) || run.loadPoint <= 0 || points.has(run.loadPoint)) {
      throw new Error("invalid or duplicate measured load point");
    }
    points.add(run.loadPoint);
    if (evaluateSlo(run).status !== "pass") break;
    highest = run.loadPoint;
  }
  return highest;
}

/** Validate text intended for publication, not explanatory non-claim documentation. */
export function assertCapacityText(text: string, highestMeasured: number | null): void {
  if (/\b100\s*(?:m|million)\b|\b1,?500\b/i.test(text)) {
    throw new Error("forbidden capacity text: unsupported 100M/1,500 claim");
  }
  const claim = /(\d[\d,]*)\s+(?:(?:agent|collab|provider)\s+)?(users|browser viewers|browsers|members|operations)\b/gi;
  for (const match of text.matchAll(claim)) {
    const value = Number(match[1]!.replaceAll(",", ""));
    if (highestMeasured === null) throw new Error("unmeasured capacity cannot be published");
    if (value > highestMeasured) {
      throw new Error(`capacity claim exceeds highest passing measured point ${highestMeasured}`);
    }
  }
}

export function capacityStatement(runs: MeasuredRun[], conditions: string): string {
  const highest = highestPassing(runs);
  if (highest === null) return `No passing measured load point under ${conditions}; REAL LOAD RUNS PENDING.`;
  const subject = {
    agent: "agent users",
    browser: "browser viewers",
    collab: "collab members",
    provider: "provider operations",
  }[runs[0]!.kind];
  const statement = `Tested up to ${highest} ${subject} under ${conditions}; no extrapolation.`;
  assertCapacityText(statement, highest);
  return statement;
}

export interface ReleaseTargetProfile {
  baseUrlEnv: string;
  wsBaseEnv: string;
  databaseUrlEnv: string;
  redisQUrlEnv: string;
  mockLlmUrlEnv: string;
  queuePrefixEnv: string;
}

export interface ReleaseProfile {
  schemaVersion: 1;
  name: string;
  series: string;
  kind: ReleaseKind;
  loadPoint: number;
  runner: "scenario" | "capacity" | "observed";
  thresholds: "smoke" | "full" | "external";
  observationEnv: string;
  target?: ReleaseTargetProfile;
  scenario?: LoadProfile;
  capacity?: CapacityProfile;
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`release profile: ${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function text(value: unknown, label: string): string {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`release profile: ${label} is required`);
  return value;
}

function positive(value: unknown, label: string, allowZero = false): number {
  if (!isFiniteNumber(value) || (allowZero ? value < 0 : value <= 0)) {
    throw new Error(`release profile: ${label} must be ${allowZero ? "non-negative" : "positive"}`);
  }
  return value;
}

function integer(value: unknown, label: string, allowZero = false): number {
  const number = positive(value, label, allowZero);
  if (!Number.isSafeInteger(number)) throw new Error(`release profile: ${label} must be an integer`);
  return number;
}

function parseTarget(value: unknown): ReleaseTargetProfile {
  const target = record(value, "target");
  const keys: Array<keyof ReleaseTargetProfile> = [
    "baseUrlEnv", "wsBaseEnv", "databaseUrlEnv", "redisQUrlEnv", "mockLlmUrlEnv", "queuePrefixEnv",
  ];
  return Object.fromEntries(keys.map((key) => [key, text(target[key], `target.${key}`)])) as unknown as ReleaseTargetProfile;
}

function parseScenario(value: unknown): LoadProfile {
  const scenario = record(value, "scenario");
  const reconnect = scenario.reconnectEveryMs;
  const profile: LoadProfile = {
    users: integer(scenario.users, "scenario.users"),
    durationMs: positive(scenario.durationMs, "scenario.durationMs"),
    rampMs: positive(scenario.rampMs, "scenario.rampMs", true),
    runsPerUserEveryMs: positive(scenario.runsPerUserEveryMs, "scenario.runsPerUserEveryMs"),
    sandboxDutyCycle: positive(scenario.sandboxDutyCycle, "scenario.sandboxDutyCycle", true),
    browserUsers: integer(scenario.browserUsers, "scenario.browserUsers", true),
    schedules: integer(scenario.schedules, "scenario.schedules", true),
    reconnectEveryMs: reconnect === null ? null : positive(reconnect, "scenario.reconnectEveryMs"),
  };
  if (profile.sandboxDutyCycle > 1) throw new Error("release profile: sandboxDutyCycle must be <= 1");
  if (scenario.spike !== undefined) {
    const spike = record(scenario.spike, "scenario.spike");
    profile.spike = {
      atMs: positive(spike.atMs, "scenario.spike.atMs", true),
      extraConcurrentRuns: integer(spike.extraConcurrentRuns, "scenario.spike.extraConcurrentRuns"),
      durationMs: positive(spike.durationMs, "scenario.spike.durationMs"),
    };
  }
  return profile;
}

function parseCapacity(value: unknown): CapacityProfile {
  const capacity = record(value, "capacity");
  const profile: CapacityProfile = {
    users: integer(capacity.users, "capacity.users"),
    rampMs: positive(capacity.rampMs, "capacity.rampMs", true),
    settleMs: positive(capacity.settleMs, "capacity.settleMs", true),
    measureMs: positive(capacity.measureMs, "capacity.measureMs"),
    sendEveryMinMs: positive(capacity.sendEveryMinMs, "capacity.sendEveryMinMs"),
    sendEveryMaxMs: positive(capacity.sendEveryMaxMs, "capacity.sendEveryMaxMs"),
    toolShare: positive(capacity.toolShare, "capacity.toolShare", true),
    studioUsers: integer(capacity.studioUsers, "capacity.studioUsers", true),
    studioEveryMs: positive(capacity.studioEveryMs, "capacity.studioEveryMs"),
    browserUsers: integer(capacity.browserUsers, "capacity.browserUsers", true),
    runTimeoutMs: positive(capacity.runTimeoutMs, "capacity.runTimeoutMs"),
  };
  if (profile.toolShare > 1 || profile.sendEveryMaxMs < profile.sendEveryMinMs) {
    throw new Error("release profile: invalid capacity toolShare/send interval");
  }
  if (capacity.burst !== undefined) {
    const burst = record(capacity.burst, "capacity.burst");
    profile.burst = {
      atMs: positive(burst.atMs, "capacity.burst.atMs", true),
      windowMs: positive(burst.windowMs, "capacity.burst.windowMs"),
    };
  }
  return profile;
}

export function parseReleaseProfile(value: unknown): ReleaseProfile {
  const input = record(value, "root");
  if (input.schemaVersion !== 1) throw new Error("release profile: schemaVersion must be 1");
  const kind = text(input.kind, "kind");
  if (!(["agent", "collab", "browser", "provider"] as string[]).includes(kind)) {
    throw new Error("release profile: invalid kind");
  }
  const runner = text(input.runner, "runner");
  if (!(["scenario", "capacity", "observed"] as string[]).includes(runner)) {
    throw new Error("release profile: invalid runner");
  }
  const thresholds = text(input.thresholds, "thresholds");
  if (!(["smoke", "full", "external"] as string[]).includes(thresholds)) {
    throw new Error("release profile: invalid thresholds");
  }
  const profile: ReleaseProfile = {
    schemaVersion: 1,
    name: text(input.name, "name"),
    series: text(input.series, "series"),
    kind: kind as ReleaseKind,
    loadPoint: integer(input.loadPoint, "loadPoint"),
    runner: runner as ReleaseProfile["runner"],
    thresholds: thresholds as ReleaseProfile["thresholds"],
    observationEnv: text(input.observationEnv, "observationEnv"),
  };
  if (profile.runner === "scenario") {
    profile.target = parseTarget(input.target);
    profile.scenario = parseScenario(input.scenario);
    if (profile.scenario.users !== profile.loadPoint) throw new Error("release profile: loadPoint must equal scenario.users");
    if (profile.thresholds === "external") throw new Error("release profile: scenario requires smoke/full thresholds");
  } else if (profile.runner === "capacity") {
    profile.target = parseTarget(input.target);
    profile.capacity = parseCapacity(input.capacity);
    if (profile.capacity.users !== profile.loadPoint) throw new Error("release profile: loadPoint must equal capacity.users");
  } else if (profile.thresholds !== "external") {
    throw new Error("release profile: observed runner requires external thresholds");
  }
  return profile;
}
