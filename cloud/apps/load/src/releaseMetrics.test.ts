import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { ShardResult } from "./capacity.js";
import { LatencyHistogram } from "./hdr.js";
import type { LoadReport } from "./scenario.js";
import {
  capacityRun,
  parseReleaseGateArgs,
  runReleaseGateCli,
  safeConfigurationUrl,
  scenarioRun,
  supplement,
} from "./releaseGateCli.js";
import {
  assertCapacityText,
  capacityStatement,
  evaluateSlo,
  highestPassing,
  parseReleaseProfile,
  type MeasuredRun,
  type ProviderMode,
  type RatioMeasurement,
  type ResourceMeasurement,
} from "./releaseMetrics.js";

const builds = {
  gateway: "gateway-test-build",
  worker: "worker-test-build",
  web: "web-test-build",
  android: "android-test-build",
  load: "load-test-build",
};

function resource(max = 10, unit = "MiB"): ResourceMeasurement {
  return { samples: 3, max, mean: max / 2, unit, source: "unit-test sampler" };
}

function ratio(percent: number): RatioMeasurement {
  return { percent, samples: 1_000, source: "unit-test telemetry" };
}

function percentiles(source = "unit-test latency") {
  return { p50: 0, p95: 0, p99: 0, samples: 1_000, source };
}

function environment(mode: ProviderMode): MeasuredRun["environment"] {
  return {
    name: "isolated-unit-test",
    hardware: {
      cpuCores: 8,
      memoryMb: 16_384,
      platform: "test",
      source: "unit-test hardware",
    },
    containerLimits: {
      gateway: { cpuCores: 1, memoryMb: 1_024, source: "unit-test limits" },
    },
    database: { url: "postgres://127.0.0.1/test", config: {} },
    redis: { url: "redis://127.0.0.1/0", config: {} },
    r2: { bucket: "isolated-test", config: {} },
    model: { name: "unit-test-model", config: {} },
    provider: { name: mode === "mock" ? "mock-llm" : "live-test-provider", mode, config: {} },
  };
}

function passingAt(point: number, overrides: Partial<MeasuredRun> = {}): MeasuredRun {
  return {
    runId: `run-${point}`,
    buildIds: { ...builds },
    environment: environment("mock"),
    profile: `beta${point}`,
    series: "beta",
    kind: "agent",
    loadPoint: point,
    samples: 1_000,
    duration: 60_000,
    p50: 0,
    p95: 0,
    p99: 0,
    latencySamples: 1_000,
    latencySource: "unit-test event latency",
    queue: percentiles("unit-test queue latency"),
    firstToken: percentiles("unit-test first-token latency"),
    completion: 985,
    failure: 15,
    cancellation: { user: 5, injected: 5, other: 0 },
    lost: 0,
    duplicates: 0,
    integrity: {
      samples: 1_000,
      groundTruth: true,
      mirror: true,
      source: "unit-test real integrity diff",
    },
    crossTenantFailures: { count: 0, samples: 100, source: "unit-test tenant canaries" },
    securityFailures: { count: 0, samples: 100, source: "unit-test security canaries" },
    availability: ratio(100),
    crashFreeSessions: ratio(100),
    anr: ratio(0),
    cpu: resource(50, "percent"),
    memory: resource(1_024),
    browserMemory: null,
    connections: {
      database: resource(20, "connections"),
      redis: resource(30, "connections"),
    },
    modelCost: { amount: 0.01, currency: "USD", samples: 1_000, sources: ["litellm"] },
    provider: {
      mode: "mock",
      requestSamples: 1_000,
      liveRequestSamples: null,
      rateLimitObservations: null,
      perProvider: null,
      lazyConnections: null,
      schemaBudget: null,
      oauthRefreshStorm: null,
    },
    browser: null,
    collab: null,
    harness: { checked: true, thresholds: "smoke", failures: [] },
    status: "pass",
    notes: [],
    ...overrides,
  };
}

function liveAt(point: number): MeasuredRun {
  const run = passingAt(point);
  return {
    ...run,
    environment: environment("live"),
    provider: { ...run.provider!, mode: "live", liveRequestSamples: 1_000, rateLimitObservations: 10 },
  };
}

function browserAt(point = 10): MeasuredRun {
  return passingAt(point, {
    profile: "browser-viewers",
    series: "browser",
    kind: "browser",
    browserMemory: resource(512),
    browser: {
      viewerSamples: 100,
      maxConcurrentViewers: point,
      frameSamples: 1_000,
      source: "unit-test browser frames",
    },
  });
}

function providerAt(point = 10): MeasuredRun {
  return passingAt(point, {
    profile: "provider-catalog",
    series: "provider",
    kind: "provider",
    provider: {
      mode: "mock",
      requestSamples: 1_000,
      liveRequestSamples: null,
      rateLimitObservations: 20,
      perProvider: {
        "mock-catalog": { requestSamples: 1_000, rateLimitObservations: 20 },
      },
      lazyConnections: { ...resource(4, "connections"), limit: 4 },
      schemaBudget: {
        samples: 20,
        maxBytes: 32_000,
        budgetBytes: 32_000,
        violations: 0,
        source: "unit-test schema budget",
      },
      oauthRefreshStorm: {
        samples: 20,
        attempts: 100,
        unexpectedFailures: 0,
        duplicateRefreshes: 0,
        source: "unit-test OAuth refresh storm",
      },
    },
  });
}

function collabAt(point = 50): MeasuredRun {
  return passingAt(point, {
    profile: "collab50",
    series: "collab",
    kind: "collab",
    collab: {
      members: point,
      ownerIncluded: true,
      joinSamples: 100,
      competingJoinSamples: 50,
      turnSamples: 100,
      competingTurnSamples: 50,
      longPollSamples: 100,
      maxSenderLeases: 1,
      hostAccountingSamples: 100,
      senderAccountingSamples: 100,
      unexpectedFailures: 0,
      source: "unit-test collab harness",
    },
  });
}

function scenarioReport(runId: string): LoadReport {
  return {
    runId,
    startedAt: "2026-10-24T00:00:00.000Z",
    durationMs: 60_000,
    users: 10,
    runsStarted: 100,
    runsCompleted: 100,
    runsFailed: 0,
    runsFailedUnattributed: 0,
    eventDelivery: { p50Ms: 0, p95Ms: 10, p99Ms: 20, samples: 1_000 },
    replay: { p95Ms: 10, maxMs: 20, reconnects: 10, samples: 10 },
    integrity: { lostEvents: 0, duplicateEvents: 0, gapsVsMirror: 0 },
    admission: {
      maxObservedActiveSandboxes: 1,
      queuedAtCap: 1,
      queuedAtCapBasis: "accepted-not-started-peak",
      rejectedAtCap: 0,
      rejectedAtCapBasis: "run_failed",
      ptySandboxBusy: 0,
      ptySandboxUnavailable: 0,
      acceptedNotTerminal: 0,
      spikeDrainMs: 0,
      spikeRuns: 0,
      spikeHeldRequests: 0,
    },
    memory: { gatewayMaxRssMb: 100, hostMemAvailableMinMb: 4_096, workerMaxRssMb: 200 },
    harness: { maxPendingFrames: 1, latencyFloorP95Ms: 1, invalidFrames: 0 },
    scheduleRuns: { created: 0, fired: 0, duplicated: 0, missed: 0 },
    thresholdFailures: [],
    notes: [],
  };
}

describe("evaluateSlo", () => {
  it("rejects empty samples instead of manufacturing a pass", () => {
    expect(() => evaluateSlo({ samples: 0 } as MeasuredRun)).toThrow(/missing measurements/i);
    expect(() => evaluateSlo(passingAt(10, { samples: 0 }))).toThrow(/missing measurements/i);
  });

  it("accepts measured zero latency values", () => {
    const result = evaluateSlo(passingAt(10));
    expect(result.status).toBe("pass");
    expect(result.gates.find((gate) => gate.name === "latency")?.actual).toBe(0);
    expect(result.gates.find((gate) => gate.name === "queueLatency")?.actual).toBe(0);
    expect(result.gates.find((gate) => gate.name === "firstTokenLatency")?.actual).toBe(0);
  });

  it("marks missing crash and ANR facts unmeasured, never passed", () => {
    const result = evaluateSlo(passingAt(10, { crashFreeSessions: null, anr: null }));
    expect(result.status).toBe("unmeasured");
    expect(result.unmeasuredGates).toEqual(expect.arrayContaining(["crashFreeSessions", "anr"]));
    expect(result.gates.find((gate) => gate.name === "crashFreeSessions")?.status).toBe("unmeasured");
    expect(result.gates.find((gate) => gate.name === "anr")?.status).toBe("unmeasured");
  });

  it("enforces availability, crash-free, and ANR thresholds exactly", () => {
    expect(evaluateSlo(passingAt(10, {
      availability: ratio(99.5), crashFreeSessions: ratio(99.5), anr: ratio(0.5),
    })).status).toBe("pass");
    expect(evaluateSlo(passingAt(10, { availability: ratio(99.49) })).status).toBe("fail");
    expect(evaluateSlo(passingAt(10, { crashFreeSessions: ratio(99.49) })).status).toBe("fail");
    expect(evaluateSlo(passingAt(10, { anr: ratio(0.51) })).status).toBe("fail");
  });

  it("excludes only actual user/injected cancellations from run_failed", () => {
    const passing = evaluateSlo(passingAt(10));
    expect(passing.effectiveSamples).toBe(990);
    expect(passing.runFailedPct).toBeCloseTo((5 / 990) * 100, 8);
    expect(passing.status).toBe("pass");

    const unclassified = evaluateSlo(passingAt(10, {
      cancellation: { user: 0, injected: 0, other: 10 },
    }));
    expect(unclassified.effectiveSamples).toBe(1_000);
    expect(unclassified.runFailedPct).toBe(1.5);
    expect(unclassified.status).toBe("fail");
    expect(unclassified.failedGates).toContain("runFailed");
  });

  it("fails closed on inconsistent cancellation evidence", () => {
    expect(() => evaluateSlo(passingAt(10, {
      cancellation: { user: 10, injected: 10, other: 0 },
    }))).toThrow(/cancellation/i);
    expect(() => evaluateSlo(passingAt(10, { completion: 1_000 }))).toThrow(/completion/i);
  });

  it("requires zero measured integrity, cross-tenant, and security failures", () => {
    expect(evaluateSlo(passingAt(10, { lost: 1 })).status).toBe("fail");
    expect(evaluateSlo(passingAt(10, { duplicates: 1 })).status).toBe("fail");
    expect(evaluateSlo(passingAt(10, {
      crossTenantFailures: { count: 1, samples: 100, source: "test" },
    })).status).toBe("fail");
    expect(evaluateSlo(passingAt(10, {
      securityFailures: { count: 1, samples: 100, source: "test" },
    })).status).toBe("fail");
    expect(evaluateSlo(passingAt(10, { integrity: null, lost: null, duplicates: null })).status)
      .toBe("unmeasured");
  });

  it("marks missing provider and live-provider facts unmeasured", () => {
    expect(evaluateSlo(passingAt(10, { provider: null })).status).toBe("unmeasured");
    const missingContainerLimit = passingAt(10);
    missingContainerLimit.environment.containerLimits.gateway!.memoryMb = null;
    const missingLimit = evaluateSlo(missingContainerLimit);
    expect(missingLimit.status).toBe("unmeasured");
    expect(missingLimit.unmeasuredGates).toContain("environment");
    const live = liveAt(10);
    const missingLive = evaluateSlo({
      ...live,
      provider: { ...live.provider!, liveRequestSamples: null },
    });
    expect(missingLive.status).toBe("unmeasured");
    expect(missingLive.unmeasuredGates).toContain("liveProvider");
    expect(evaluateSlo({ ...live, modelCost: null }).status).toBe("unmeasured");
  });
});

describe("highestPassing", () => {
  it("reports only the highest passing measured point", () => {
    expect(highestPassing([passingAt(10), passingAt(50, { availability: ratio(99) })])).toBe(10);
    expect(highestPassing([passingAt(10), passingAt(25), passingAt(50)])).toBe(50);
  });

  it("stops at a failing 50 to 100 step even if a later report says pass", () => {
    const result = highestPassing([
      passingAt(10),
      passingAt(50, { availability: ratio(99) }),
      passingAt(100),
    ]);
    expect(result).toBe(10);
    expect(highestPassing([passingAt(50, { availability: ratio(99) }), passingAt(100)])).toBeNull();
  });

  it("never merges mock LLM and live provider reports", () => {
    expect(() => highestPassing([passingAt(10), liveAt(25)])).toThrow(/mock.*live|live.*mock/i);
    expect(highestPassing([liveAt(10), liveAt(25)])).toBe(25);
  });

  it("never merges build, environment, kind, or series evidence", () => {
    expect(() => highestPassing([
      passingAt(10),
      passingAt(25, { buildIds: { ...builds, worker: "different-worker" } }),
    ])).toThrow(/build/i);
    expect(() => highestPassing([passingAt(10), browserAt(25)])).toThrow(/kind|series/i);
  });
});

describe("specialized capacity evidence", () => {
  it("does not let HTTP throughput masquerade as browser-viewer capacity", () => {
    expect(evaluateSlo(browserAt()).status).toBe("pass");
    const missing = evaluateSlo({ ...browserAt(), browserMemory: null });
    expect(missing.status).toBe("unmeasured");
    expect(missing.unmeasuredGates).toContain("browserMemory");
    expect(evaluateSlo({ ...browserAt(), browser: null }).status).toBe("unmeasured");
  });

  it("requires lazy connections, schema budget, and OAuth refresh-storm facts", () => {
    expect(evaluateSlo(providerAt()).status).toBe("pass");
    const provider = providerAt().provider!;
    for (const key of ["lazyConnections", "schemaBudget", "oauthRefreshStorm"] as const) {
      const result = evaluateSlo({ ...providerAt(), provider: { ...provider, [key]: null } });
      expect(result.status).toBe("unmeasured");
      expect(result.unmeasuredGates).toContain(key);
    }
    expect(evaluateSlo({
      ...providerAt(),
      provider: { ...provider, schemaBudget: { ...provider.schemaBudget!, maxBytes: 32_001 } },
    }).status).toBe("fail");
    const noPerProvider = evaluateSlo({
      ...providerAt(), provider: { ...provider, perProvider: null },
    });
    expect(noPerProvider.status).toBe("unmeasured");
    expect(noPerProvider.unmeasuredGates).toContain("providerRateLimits");
    expect(evaluateSlo({
      ...providerAt(),
      provider: { ...provider, schemaBudget: { ...provider.schemaBudget!, maxBytes: -1 } },
    }).status).toBe("unmeasured");
  });

  it("requires the actual 50-member collab scenario and one sender lease", () => {
    expect(evaluateSlo(collabAt()).status).toBe("pass");
    expect(evaluateSlo({ ...collabAt(), collab: null }).status).toBe("unmeasured");
    expect(evaluateSlo({
      ...collabAt(), collab: { ...collabAt().collab!, maxSenderLeases: 2 },
    }).status).toBe("fail");
    expect(evaluateSlo({
      ...collabAt(), collab: { ...collabAt().collab!, ownerIncluded: false },
    }).status).toBe("fail");
    expect(evaluateSlo({
      ...collabAt(), collab: { ...collabAt().collab!, competingJoinSamples: 0 },
    }).status).toBe("unmeasured");
  });
});

describe("publishable capacity text", () => {
  it("rejects forbidden or extrapolated capacity claims", () => {
    expect(() => assertCapacityText("Supports 100M users", 100)).toThrow(/forbidden/i);
    expect(() => assertCapacityText("Capacity: 1,500 browsers", 100)).toThrow(/forbidden/i);
    expect(() => assertCapacityText("tested up to 100 users under staging", 50)).toThrow(/exceeds/i);
    expect(() => assertCapacityText("tested up to 10 users under staging", null)).toThrow(/unmeasured/i);
    expect(() => assertCapacityText("tested up to 100 users under staging", 100)).not.toThrow();
  });

  it("emits only the measured point and keeps pending runs honest", () => {
    expect(capacityStatement([passingAt(10), passingAt(25)], "isolated staging"))
      .toBe("Tested up to 25 agent users under isolated staging; no extrapolation.");
    expect(capacityStatement([], "isolated staging")).toMatch(/real load runs pending/i);
  });
});

describe("same-run supplement provenance", () => {
  it("rejects stale availability, crash/ANR, and cost evidence by embedded run ID", () => {
    const base = passingAt(10, {
      runId: "release-current",
      availability: null,
      crashFreeSessions: null,
      anr: null,
      modelCost: null,
    });
    const stale = passingAt(10, { runId: "release-previous" });
    expect(() => supplement(base, stale, "mock")).toThrow(/runId/i);
  });

  it("requires exact build, environment, series, kind, and load-point identity", () => {
    const base = passingAt(10, { runId: "release-current" });
    expect(() => supplement(base, passingAt(10, {
      runId: "release-current", buildIds: { ...builds, worker: "older-worker" },
    }), "mock")).toThrow(/build/i);
    expect(() => supplement(base, passingAt(10, {
      runId: "release-current", environment: { ...environment("mock"), name: "older-staging" },
    }), "mock")).toThrow(/environment/i);
    expect(() => supplement(base, passingAt(10, {
      runId: "release-current", series: "older-series",
    }), "mock")).toThrow(/series/i);
    expect(() => supplement(base, passingAt(10, {
      runId: "release-current", kind: "provider",
    }), "mock")).toThrow(/kind/i);
    expect(() => supplement(base, passingAt(25, {
      runId: "release-current", profile: "beta10",
    }), "mock")).toThrow(/loadPoint/i);
  });

  it("rejects stale browser supplements instead of importing capacity facts", () => {
    const base = browserAt(10);
    base.runId = "release-current";
    base.browser = null;
    base.availability = null;
    base.modelCost = null;
    const stale = browserAt(10);
    stale.runId = "release-previous";
    expect(() => supplement(base, stale, "mock")).toThrow(/runId/i);
  });

  it("accepts only matching same-run supplements and preserves measured facts", () => {
    const base = passingAt(10, {
      runId: "release-current", queue: null, availability: null, modelCost: null,
    });
    const evidence = passingAt(10, { runId: "release-current" });
    const merged = supplement(base, evidence, "mock");
    expect(merged.queue).toEqual(evidence.queue);
    expect(merged.availability).toEqual(evidence.availability);
    expect(merged.modelCost).toEqual(evidence.modelCost);
  });

  it("rejects scenario results that do not carry the generated run identity", () => {
    const profile = parseReleaseProfile(JSON.parse(readFileSync(
      new URL("../profiles/beta10.json", import.meta.url), "utf8",
    )));
    const base = passingAt(10, { runId: "release-current", profile: "beta10" });
    const resources = {
      cpu: null,
      memory: null,
      browserMemory: null,
      connections: { database: null, redis: null },
      notes: [],
    };
    expect(() => scenarioRun(profile, scenarioReport("release-current"), base, resources)).not.toThrow();
    expect(() => scenarioRun(profile, scenarioReport("release-previous"), base, resources))
      .toThrow(/runId/i);
  });
});

describe("release gate CLI", () => {
  it("does not promote cumulative browser-live counters to a concurrency high-water mark", () => {
    const profile = parseReleaseProfile(JSON.parse(readFileSync(
      new URL("../profiles/browser-viewers.json", import.meta.url), "utf8",
    )));
    const empty = new LatencyHistogram(1_000).serialize();
    const shard: ShardResult = {
      shard: 0,
      users: 10,
      connected: 10,
      histograms: {
        send202: empty,
        firstToken: empty,
        wsLag: empty,
        runTotal: empty,
        burstSend202: empty,
        burstFirstToken: empty,
        studio: empty,
        connect: empty,
      },
      runId: "run-10",
      counters: {
        runsCompleted: 1,
        browserAttachOk: 10,
        browserLiveUsersObserved: 10,
        browserFrames: 100,
      },
      statuses: {},
      failureCodes: {},
      errors: [],
      harness: { loopDelayP99Ms: 1, loopDelayMaxMs: 2, maxInFlightRuns: 1 },
    };
    const measured = capacityRun(profile, shard, 1_000, passingAt(10), {
      cpu: null,
      memory: null,
      browserMemory: resource(512),
      connections: { database: null, redis: null },
      notes: [],
    });
    expect(measured.browser).toBeNull();
    expect(() => capacityRun(profile, { ...shard, runId: "older-run" }, 1_000, passingAt(10), {
      cpu: null,
      memory: null,
      browserMemory: resource(512),
      connections: { database: null, redis: null },
      notes: [],
    })).toThrow(/runId/i);
  });

  it("parses only the documented profile/out/live arguments", () => {
    expect(parseReleaseGateArgs(["--profile", "profile.json", "--out", "result", "--live"]))
      .toEqual({ profile: "profile.json", out: "result", live: true });
    expect(() => parseReleaseGateArgs(["--profile", "profile.json"])).toThrow(/--out/);
    expect(() => parseReleaseGateArgs(["--profile", "profile.json", "--out", "x", "--users", "100"]))
      .toThrow(/unknown argument/);
  });

  it("redacts credentials and query values from recorded configuration URLs", () => {
    expect(safeConfigurationUrl("postgres://user:secret@example.test/db?token=secret&sslmode=require"))
      .toBe("postgres://example.test/db");
    expect(safeConfigurationUrl("redis://:private@127.0.0.1:6379/0"))
      .toBe("redis://127.0.0.1:6379/0");
    expect(safeConfigurationUrl("not a URL with secret")).toBeNull();
  });

  it("writes hardware, configuration nulls, and failed gates without starting load on preflight failure", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-preflight-"));
    const prefix = join(directory, "evidence");
    let loadCalls = 0;
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/beta10.json", import.meta.url)),
      "--out", prefix,
    ], {
      env: {},
      runScenario: async () => { loadCalls += 1; throw new Error("load must not start"); },
    });
    expect(code).not.toBe(0);
    expect(loadCalls).toBe(0);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      failedGates: string[];
      buildIds: Record<string, string | null>;
      environment: { hardware: { cpuCores: number }; database: { url: string | null } };
    };
    expect(report.status).toBe("fail");
    expect(report.failedGates).toContain("preflight");
    expect(report.environment.hardware.cpuCores).toBeGreaterThan(0);
    expect(report.environment.database.url).toBeNull();
    expect(Object.values(report.buildIds).every((value) => value === null)).toBe(true);
    const markdown = await readFile(`${prefix}.md`, "utf8");
    expect(markdown).toContain("failedGates");
    expect(markdown).toContain("preflight");
  });

  it("writes observed evidence and failed SLO gates on a nonzero measured exit", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-observed-"));
    const prefix = join(directory, "collab");
    const observationPath = join(directory, "observation.json");
    const measured = collabAt();
    measured.runId = "same-observed-run";
    measured.availability = ratio(99);
    await writeFile(observationPath, JSON.stringify({
      runId: measured.runId,
      profile: "collab50",
      buildIds: builds,
      providerMode: "mock",
      evidence: measured,
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/collab50.json", import.meta.url)),
      "--out", prefix,
    ], {
      env: { RELEASE_COLLAB50_OBSERVATION: observationPath },
      now: () => Date.parse("2026-10-24T00:00:00.000Z"),
    });
    expect(code).toBe(1);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      run: { samples: number; runId: string };
      evaluation: { failedGates: string[] };
    };
    expect(report.status).toBe("fail");
    expect(report.run.samples).toBe(1_000);
    expect(report.run.runId).toBe("same-observed-run");
    expect(report.evaluation.failedGates).toContain("availability");
    expect(await readFile(`${prefix}.md`, "utf8")).toContain("availability");
  });

  it("rejects stale identity embedded inside observed evidence", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-stale-"));
    const prefix = join(directory, "collab");
    const observationPath = join(directory, "observation.json");
    const stale = collabAt();
    stale.runId = "older-run";
    stale.buildIds = { ...builds, worker: "older-worker" };
    await writeFile(observationPath, JSON.stringify({
      runId: "current-run",
      profile: "collab50",
      buildIds: builds,
      providerMode: "mock",
      evidence: stale,
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/collab50.json", import.meta.url)),
      "--out", prefix,
    ], { env: { RELEASE_COLLAB50_OBSERVATION: observationPath } });
    expect(code).toBe(2);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      failedGates: string[];
      run: unknown;
    };
    expect(report.failedGates).toContain("evidence");
    expect(report.run).toBeNull();
  });

  it("rejects a live envelope around embedded mock evidence without omitting live gates", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-live-envelope-"));
    const prefix = join(directory, "provider");
    const observationPath = join(directory, "observation.json");
    await writeFile(observationPath, JSON.stringify({
      runId: "run-10",
      profile: "provider-catalog",
      buildIds: builds,
      providerMode: "live",
      evidence: providerAt(),
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/provider-catalog.json", import.meta.url)),
      "--out", prefix,
      "--live",
    ], { env: { RELEASE_PROVIDER_CATALOG_OBSERVATION: observationPath } });
    expect(code).not.toBe(0);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      providerMode: string;
      capacityStatement: string;
      run: { status: string } | null;
    };
    expect(report.status).not.toBe("pass");
    expect(report.providerMode).toBe("live");
    expect(report.capacityStatement).toMatch(/REAL LOAD RUNS PENDING/i);
    expect(report.run?.status ?? "fail").not.toBe("pass");
    expect(await readFile(`${prefix}.md`, "utf8")).toContain("REAL LOAD RUNS PENDING");
  });

  it("rejects a mock envelope around embedded live evidence in the opposite direction", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-opposite-mode-"));
    const prefix = join(directory, "provider");
    const observationPath = join(directory, "observation.json");
    const evidence = providerAt();
    evidence.environment = environment("live");
    evidence.provider = { ...evidence.provider!, mode: "live", liveRequestSamples: 1_000 };
    await writeFile(observationPath, JSON.stringify({
      runId: "run-10",
      profile: "provider-catalog",
      buildIds: builds,
      providerMode: "mock",
      evidence,
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/provider-catalog.json", import.meta.url)),
      "--out", prefix,
    ], { env: { RELEASE_PROVIDER_CATALOG_OBSERVATION: observationPath } });
    expect(code).not.toBe(0);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      capacityStatement: string;
      run: { status: string } | null;
    };
    expect(report.status).toBe("fail");
    expect(report.capacityStatement).toMatch(/REAL LOAD RUNS PENDING/i);
    expect(report.run?.status ?? "fail").not.toBe("pass");
  });

  it("requires actual live responses even when every provider mode says live", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-live-facts-"));
    const prefix = join(directory, "provider");
    const observationPath = join(directory, "observation.json");
    const evidence = providerAt();
    evidence.environment = environment("live");
    evidence.provider = { ...evidence.provider!, mode: "live", liveRequestSamples: null };
    await writeFile(observationPath, JSON.stringify({
      runId: "run-10",
      profile: "provider-catalog",
      buildIds: builds,
      providerMode: "live",
      evidence,
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/provider-catalog.json", import.meta.url)),
      "--out", prefix,
      "--live",
    ], { env: { RELEASE_PROVIDER_CATALOG_OBSERVATION: observationPath } });
    expect(code).toBe(1);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      run: { status: string };
      evaluation: { unmeasuredGates: string[] };
    };
    expect(report.status).toBe("unmeasured");
    expect(report.run.status).toBe("unmeasured");
    expect(report.evaluation.unmeasuredGates).toContain("liveProvider");
  });

  it("keeps missing observed provider facts unmeasured rather than passing or borrowing the envelope mode", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-missing-provider-"));
    const prefix = join(directory, "collab");
    const observationPath = join(directory, "observation.json");
    const evidence = collabAt();
    evidence.provider = null;
    await writeFile(observationPath, JSON.stringify({
      runId: "run-50",
      profile: "collab50",
      buildIds: builds,
      providerMode: "mock",
      evidence,
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/collab50.json", import.meta.url)),
      "--out", prefix,
    ], { env: { RELEASE_COLLAB50_OBSERVATION: observationPath } });
    expect(code).toBe(1);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      run: { status: string };
      evaluation: { unmeasuredGates: string[] };
    };
    expect(report.status).toBe("unmeasured");
    expect(report.run.status).toBe("unmeasured");
    expect(report.evaluation.unmeasuredGates).toContain("provider");
  });

  it("overwrites untrusted nested pass status when evaluation throws", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-evaluation-error-"));
    const prefix = join(directory, "collab");
    const observationPath = join(directory, "observation.json");
    const evidence = collabAt();
    evidence.samples = 0;
    evidence.status = "pass";
    await writeFile(observationPath, JSON.stringify({
      runId: "run-50",
      profile: "collab50",
      buildIds: builds,
      providerMode: "mock",
      evidence,
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/collab50.json", import.meta.url)),
      "--out", prefix,
    ], { env: { RELEASE_COLLAB50_OBSERVATION: observationPath } });
    expect(code).not.toBe(0);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      failedGates: string[];
      run: { status: string };
      capacityStatement: string;
    };
    expect(report.status).toBe("fail");
    expect(report.failedGates).toContain("evaluation");
    expect(report.run.status).toBe("fail");
    expect(report.capacityStatement).toMatch(/REAL LOAD RUNS PENDING/i);
    expect(await readFile(`${prefix}.md`, "utf8")).not.toContain("status: **PASS**");
  });

  it("rejects a mock observation for a live invocation instead of merging modes", async () => {
    const directory = await mkdtemp(join(tmpdir(), "ovid-release-gate-live-"));
    const prefix = join(directory, "provider");
    const observationPath = join(directory, "observation.json");
    await writeFile(observationPath, JSON.stringify({
      runId: "mock-run",
      profile: "provider-catalog",
      buildIds: builds,
      providerMode: "mock",
      evidence: providerAt(),
    }));
    const code = await runReleaseGateCli([
      "--profile", fileURLToPath(new URL("../profiles/provider-catalog.json", import.meta.url)),
      "--out", prefix,
      "--live",
    ], { env: { RELEASE_PROVIDER_CATALOG_OBSERVATION: observationPath } });
    expect(code).toBe(2);
    const report = JSON.parse(await readFile(`${prefix}.json`, "utf8")) as {
      status: string;
      failedGates: string[];
      run: unknown;
    };
    expect(report.status).toBe("fail");
    expect(report.failedGates).toContain("evidence");
    expect(report.run).toBeNull();
  });
});

describe("release profiles and report template", () => {
  const names = ["beta10", "beta25", "beta50", "beta100", "collab50", "browser-viewers", "provider-catalog"];
  const profiles = names.map((name) => {
    const text = readFileSync(new URL(`../profiles/${name}.json`, import.meta.url), "utf8");
    return parseReleaseProfile(JSON.parse(text));
  });

  it("defines only measured beta steps and separate specialized profiles", () => {
    expect(profiles.filter((profile) => profile.series === "beta").map((profile) => profile.loadPoint))
      .toEqual([10, 25, 50, 100]);
    expect(profiles.find((profile) => profile.name === "collab50")).toMatchObject({
      kind: "collab", loadPoint: 50, runner: "observed",
    });
    expect(profiles.find((profile) => profile.name === "browser-viewers")).toMatchObject({
      kind: "browser", runner: "capacity",
    });
    expect(profiles.find((profile) => profile.name === "provider-catalog")).toMatchObject({
      kind: "provider", runner: "observed",
    });
  });

  it("keeps the report template measurement-oriented", () => {
    const template = readFileSync(
      new URL("../../../deploy/SLO-LOAD-REPORT-TEMPLATE.md", import.meta.url),
      "utf8",
    );
    for (const field of ["buildIds", "environment", "queue", "firstToken", "modelCost", "failedGates"]) {
      expect(template).toContain(field);
    }
    expect(template).toContain("REAL LOAD RUNS PENDING");
    expect(template).not.toMatch(/tested up to\s+(?:100M|1,?500)/i);
  });
});
