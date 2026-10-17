import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import {
  registeredScenarios,
  runChaosScenario,
  type ScenarioName,
} from "./chaos/runner.js";
import { createStagingContext, utcDate } from "./chaos/staging.js";
// Importing the registry module registers the Task-6 scenarios; Task 7 adds
// its three to the same module.
import "./chaos/scenarios/index.js";

/**
 * Chaos CLI (Task 6):
 *
 *   node apps/load/dist/chaosCli.js --scenario <name>|all \
 *     [--out reports/chaos-<YYYYMMDD>.md]
 *
 * Runs only against the staging composition (via staging.sh), appends every
 * scenario block to the dated report, and exits non-zero if any scenario did
 * not pass. A scenario that fails its precondition is a FAIL, never skipped.
 */

interface CliOptions {
  scenario: string;
  out: string;
}

function usage(): string {
  return [
    "usage: chaosCli.js --scenario <name>|all [--out <report.md>] [--list]",
    "",
    "  scenarios are registered by the build (Task 6: redis-q-restart,",
    "  gateway-restart, postgres-restart; Task 7 adds three more)",
  ].join("\n");
}

function defaultReportPath(): string {
  // dist/chaosCli.js → package root → reports/ (the plan's committed path,
  // independent of the caller's cwd). An explicit --out stays cwd-relative.
  const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  return resolve(packageRoot, "reports", `chaos-${utcDate()}.md`);
}

function parseArgs(argv: string[]): CliOptions & { list: boolean } {
  const options: CliOptions & { list: boolean } = {
    scenario: "all",
    out: defaultReportPath(),
    list: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--list") {
      options.list = true;
      continue;
    }
    if (arg === "--help" || arg === "-h") {
      console.log(usage());
      process.exit(0);
    }
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`chaosCli: missing value for ${arg}`);
    switch (arg) {
      case "--scenario":
        options.scenario = value;
        index += 1;
        break;
      case "--out":
        options.out = resolve(process.cwd(), value);
        index += 1;
        break;
      default:
        throw new Error(`chaosCli: unknown argument ${arg}\n${usage()}`);
    }
  }
  return options;
}

export async function runChaosCli(argv: string[]): Promise<number> {
  const options = parseArgs(argv);
  const registry = registeredScenarios();

  if (options.list) {
    for (const scenario of registry) {
      console.log(`${scenario.name}: ${scenario.precondition}`);
    }
    return 0;
  }

  const known = new Set(registry.map((scenario) => scenario.name));
  let selected: ScenarioName[];
  if (options.scenario === "all") {
    selected = registry.map((scenario) => scenario.name);
  } else if (known.has(options.scenario as ScenarioName)) {
    selected = [options.scenario as ScenarioName];
  } else {
    throw new Error(
      `chaosCli: unknown scenario '${options.scenario}' (registered: ${[...known].join(", ") || "none"})`,
    );
  }
  if (selected.length === 0) {
    throw new Error("chaosCli: no scenarios registered");
  }

  const ctx = await createStagingContext({
    reportPath: options.out,
    reportHeader: [
      `# Ovid chaos report — ${new Date().toISOString()}`,
      "",
      `- target: staging (cloud/scripts/staging.sh env)`,
      `- scenarios: ${selected.join(", ")}`,
      "",
      "Every scenario gates on a proven precondition before injection and",
      "asserts the live stack unaffected before and after.",
      "",
    ].join("\n"),
  });

  const failures: string[] = [];
  // M7: a SIGINT/SIGTERM during a scenario must still restore the displaced
  // staging mock (and the worker, via the scenario's own cleanup on the next
  // iteration). close() is idempotent.
  const onSignal = (signal: NodeJS.Signals): void => {
    void ctx.close().finally(() => process.exit(signal === "SIGINT" ? 130 : 143));
  };
  process.once("SIGINT", onSignal);
  process.once("SIGTERM", onSignal);
  try {
    for (const name of selected) {
      const result = await runChaosScenario(name, ctx);
      console.log(
        `[chaos] ${result.name}: ${result.passed ? "PASS" : "FAIL"} (${result.durationMs}ms)`,
      );
      for (const assertion of result.assertions) {
        console.log(
          `[chaos]   ${assertion.passed ? "PASS" : "FAIL"} ${assertion.name}: ${assertion.detail}`,
        );
      }
      if (!result.passed) failures.push(result.name);
    }
  } finally {
    process.removeListener("SIGINT", onSignal);
    process.removeListener("SIGTERM", onSignal);
    await ctx.close();
  }

  console.log(`[chaos] report: ${options.out}`);
  if (failures.length > 0) {
    console.error(`[chaos] FAILED: ${failures.join(", ")}`);
    return 1;
  }
  console.log("[chaos] all selected scenarios passed");
  return 0;
}


const invokedDirectly =
  process.argv[1] !== undefined &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly) {
  runChaosCli(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((err: unknown) => {
      console.error(err instanceof Error ? err.message : String(err));
      process.exit(2);
    });
}
