import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { runScenario, type LoadProfile, type LoadReport, type LoadTarget } from "./scenario.js";
import {
  FULL_THRESHOLDS,
  SMOKE_THRESHOLDS,
  readMetric,
  checkThresholds,
  type LoadThreshold,
} from "./thresholds.js";

/**
 * CLI (Task 5 invokes this against staging):
 *
 *   node apps/load/dist/cli.js load \
 *     --profile smoke10|full100|<file.json> \
 *     --target staging \
 *     --out reports/load-YYYYMMDD-100u.md [--json reports/....json]
 *
 * `--target staging` shells out to `staging.sh env` (Task 1) and never
 * composes anything itself. The harness only consumes read-only surfaces.
 */

export const BUILT_IN_PROFILES: Record<string, LoadProfile> = {
  smoke10: {
    users: 10,
    durationMs: 120_000,
    rampMs: 5_000,
    runsPerUserEveryMs: 20_000,
    sandboxDutyCycle: 0.3,
    browserUsers: 0,
    schedules: 0,
    reconnectEveryMs: 30_000,
  },
  full100: {
    users: 100,
    durationMs: 1_800_000,
    rampMs: 300_000,
    runsPerUserEveryMs: 90_000,
    sandboxDutyCycle: 0.35,
    browserUsers: 4,
    schedules: 10,
    reconnectEveryMs: 60_000,
    spike: { atMs: 900_000, extraConcurrentRuns: 16, durationMs: 300_000 },
  },
};

interface CliOptions {
  profile: string;
  target: string;
  out: string | null;
  json: string | null;
  thresholds: "smoke" | "full" | null;
}

function parseArgs(argv: string[]): CliOptions {
  if (argv[0] !== "load") {
    throw new Error("usage: cli.js load --profile <name|file> --target <staging|file> --out <report.md>");
  }
  const options: CliOptions = {
    profile: "smoke10",
    target: "staging",
    out: null,
    json: null,
    thresholds: null,
  };
  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = argv[i + 1];
    if (value === undefined) throw new Error(`cli: missing value for ${arg}`);
    switch (arg) {
      case "--profile":
        options.profile = value;
        i += 1;
        break;
      case "--target":
        options.target = value;
        i += 1;
        break;
      case "--out":
        options.out = value;
        i += 1;
        break;
      case "--json":
        options.json = value;
        i += 1;
        break;
      case "--thresholds":
        if (value !== "smoke" && value !== "full") {
          throw new Error("cli: --thresholds must be smoke or full");
        }
        options.thresholds = value;
        i += 1;
        break;
      default:
        throw new Error(`cli: unknown argument ${arg}`);
    }
  }
  return options;
}

function stagingScriptPath(): string {
  const candidates = [
    process.env.STAGING_SCRIPT,
    resolve(process.cwd(), "scripts/staging.sh"),
    resolve(process.cwd(), "cloud/scripts/staging.sh"),
  ].filter((candidate): candidate is string => typeof candidate === "string");
  const found = candidates.find((candidate) => existsSync(candidate));
  if (found === undefined) {
    throw new Error(
      "cli: staging.sh not found (Task 1) — run from cloud/ or set STAGING_SCRIPT",
    );
  }
  return found;
}

function execText(command: string, args: string[]): Promise<string> {
  return new Promise((resolvePromise, reject) => {
    execFile(command, args, { encoding: "utf8", timeout: 30_000 }, (err, stdout) => {
      if (err) reject(err);
      else resolvePromise(stdout);
    });
  });
}

function parseEnv(text: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq <= 0) continue;
    env[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
  }
  return env;
}

async function resolveTarget(target: string): Promise<LoadTarget> {
  if (target !== "staging") {
    // A JSON file with the LoadTarget shape (Task 5/6 may point at a
    // second machine; location-transparent by construction).
    const text = await readFile(resolve(process.cwd(), target), "utf8");
    return JSON.parse(text) as LoadTarget;
  }

  const script = stagingScriptPath();
  const env = parseEnv(await execText("bash", [script, "env"]));
  const baseUrl = env.STAGING_GATEWAY_URL;
  const redisQUrl = env.STAGING_REDIS_Q_URL;
  const databaseUrl = env.STAGING_DATABASE_URL;
  const mockLlmUrl = env.STAGING_MOCK_LLM_URL;
  if (
    baseUrl === undefined ||
    redisQUrl === undefined ||
    databaseUrl === undefined ||
    mockLlmUrl === undefined
  ) {
    throw new Error(
      "cli: staging.sh env did not print STAGING_GATEWAY_URL/STAGING_REDIS_Q_URL/STAGING_DATABASE_URL/STAGING_MOCK_LLM_URL",
    );
  }
  const wsBase = `${baseUrl.replace(/^http/, "ws").replace(/\/+$/, "")}/cloud/ws`;
  return {
    baseUrl,
    wsBase,
    redisQUrl,
    databaseUrl,
    mockLlmUrl,
    queuePrefix: env.BULL_PREFIX ?? "bull:staging",
  };
}

async function resolveProfile(nameOrFile: string): Promise<{ name: string; profile: LoadProfile }> {
  const builtIn = BUILT_IN_PROFILES[nameOrFile];
  if (builtIn !== undefined) return { name: nameOrFile, profile: builtIn };
  const text = await readFile(resolve(process.cwd(), nameOrFile), "utf8");
  return { name: nameOrFile, profile: JSON.parse(text) as LoadProfile };
}

function formatValue(value: number | undefined): string {
  if (value === undefined) return "MISSING";
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function renderMarkdown(
  name: string,
  profile: LoadProfile,
  target: LoadTarget,
  report: LoadReport,
  thresholds: LoadThreshold[],
  failures: string[],
): string {
  const rows: Array<[string, string]> = [
    ["users", String(report.users)],
    ["durationMs", String(report.durationMs)],
    ["runsStarted", String(report.runsStarted)],
    ["runsCompleted", String(report.runsCompleted)],
    ["runsFailed", String(report.runsFailed)],
    ["eventDelivery.p50Ms", formatValue(report.eventDelivery.p50Ms)],
    ["eventDelivery.p95Ms", formatValue(report.eventDelivery.p95Ms)],
    ["eventDelivery.p99Ms", formatValue(report.eventDelivery.p99Ms)],
    ["eventDelivery.samples", String(report.eventDelivery.samples)],
    ["replay.p95Ms", formatValue(report.replay.p95Ms)],
    ["replay.maxMs", formatValue(report.replay.maxMs)],
    ["replay.reconnects", String(report.replay.reconnects)],
    ["integrity.lostEvents", String(report.integrity.lostEvents)],
    ["integrity.duplicateEvents", String(report.integrity.duplicateEvents)],
    ["integrity.gapsVsMirror", String(report.integrity.gapsVsMirror)],
    ["admission.maxObservedActiveSandboxes", String(report.admission.maxObservedActiveSandboxes)],
    ["admission.queuedAtCap", String(report.admission.queuedAtCap)],
    ["admission.rejectedAtCap", String(report.admission.rejectedAtCap)],
    ["memory.gatewayMaxRssMb", String(report.memory.gatewayMaxRssMb)],
    ["memory.workerMaxRssMb", String(report.memory.workerMaxRssMb)],
    ["memory.hostMemAvailableMinMb", String(report.memory.hostMemAvailableMinMb)],
    ["harness.maxPendingFrames", String(report.harness.maxPendingFrames)],
    ["harness.latencyFloorP95Ms", formatValue(report.harness.latencyFloorP95Ms)],
    ["scheduleRuns.fired", String(report.scheduleRuns.fired)],
    ["scheduleRuns.duplicated", String(report.scheduleRuns.duplicated)],
    ["scheduleRuns.missed", String(report.scheduleRuns.missed)],
  ];

  const thresholdRows = thresholds.map((threshold) => {
    const measured = readMetric(report, threshold.metric);
    const passed = !failures.includes(threshold.metric);
    return `| \`${threshold.metric}\` | ${threshold.op} ${threshold.value} | ${formatValue(
      measured,
    )} | ${passed ? "PASS" : "FAIL"} | ${threshold.rationale} |`;
  });

  const notes =
    report.notes === undefined || report.notes.length === 0
      ? "_none_"
      : report.notes.map((note) => `- ${note}`).join("\n");

  return [
    `# Ovid load report — ${name}`,
    "",
    `- startedAt: ${report.startedAt}`,
    `- target: ${target.baseUrl} (queue prefix \`${target.queuePrefix}\`)`,
    `- profile: ${JSON.stringify(profile)}`,
    "",
    "## Metrics",
    "",
    "| Metric | Value |",
    "|---|---|",
    ...rows.map(([metric, value]) => `| \`${metric}\` | ${value} |`),
    "",
    "## Thresholds",
    "",
    "| Metric | Required | Measured | Result | Rationale |",
    "|---|---|---|---|---|",
    ...thresholdRows,
    "",
    failures.length === 0
      ? "**Result: PASS (zero threshold failures).**"
      : `**Result: FAIL — ${failures.join(", ")}**`,
    "",
    "## Notes",
    "",
    notes,
    "",
  ].join("\n");
}

export async function runCli(argv: string[]): Promise<number> {
  const options = parseArgs(argv);
  const { name, profile } = await resolveProfile(options.profile);
  const target = await resolveTarget(options.target);
  const thresholds =
    options.thresholds === "smoke"
      ? SMOKE_THRESHOLDS
      : options.thresholds === "full"
        ? FULL_THRESHOLDS
        : name === "smoke10"
          ? SMOKE_THRESHOLDS
          : FULL_THRESHOLDS;

  console.log(
    `load: profile=${name} users=${profile.users} durationMs=${profile.durationMs} target=${target.baseUrl}`,
  );
  const report = await runScenario(profile, target);
  const failures = checkThresholds(report, thresholds);
  report.thresholdFailures = failures;

  const markdown = renderMarkdown(name, profile, target, report, thresholds, failures);
  if (options.out !== null) {
    await writeFile(resolve(process.cwd(), options.out), markdown, "utf8");
    console.log(`report written: ${options.out}`);
  } else {
    console.log(markdown);
  }
  if (options.json !== null) {
    await writeFile(
      resolve(process.cwd(), options.json),
      JSON.stringify({ report, thresholds, failures }, null, 2),
      "utf8",
    );
    console.log(`json written: ${options.json}`);
  }

  if (failures.length > 0) {
    console.error(`threshold failures: ${failures.join(", ")}`);
    return 1;
  }
  console.log("thresholds: PASS");
  return 0;
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly) {
  runCli(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((err: unknown) => {
      console.error(err instanceof Error ? err.message : String(err));
      process.exit(2);
    });
}
