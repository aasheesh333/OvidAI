import { execFile } from "node:child_process";
import type { MockLlmScript } from "../mockServer.js";

/**
 * Chaos runner — the orchestration mechanics shared by every scenario.
 *
 * Review Focus #3 is enforced HERE, not in the individual scenarios: a
 * scenario is modelled as prepare → gate → inject → verify. `runChaosScenario`
 * calls `inject` ONLY when the gate proved the vulnerable precondition. A gate
 * failure returns `passed:false` with zero injection, so a run that finished
 * before the kill (or an empty queue before the restart) can never be
 * vacuous-green.
 *
 * Review Focus #1 is enforced on both sides of every scenario: the runner
 * captures the live stack before, refuses to inject into an unhealthy live
 * stack, and calls `assertLiveUnaffected` after.
 */

export type ScenarioName =
  | "redis-q-restart"
  | "gateway-restart"
  | "postgres-restart"
  | "worker-kill"
  | "disk-pressure"
  | "clock-skew";

export interface LiveContainer {
  name: string;
  status: string;
  startedAt: string;
}

export interface LiveSnapshot {
  capturedAt: string;
  healthzStatus: number;
  containers: LiveContainer[];
  /** Non-fatal probe errors (docker unavailable, inspect failure, …). */
  errors?: string[];
}

export interface Assertion {
  name: string;
  passed: boolean;
  detail: string;
}

export interface ScenarioResult {
  name: string;
  passed: boolean;
  /** Description of the proven-vulnerable state the gate must establish. */
  precondition: string;
  assertions: Assertion[];
  durationMs: number;
}

export interface ReportExtras {
  liveBefore: LiveSnapshot;
  liveAfter?: LiveSnapshot;
  notes?: string[];
}

export interface ReportWriter {
  /** Append raw markdown to the dated chaos report. */
  append(markdown: string): Promise<void>;
  /** Append one rendered scenario block (assertions + live before/after). */
  writeScenario(result: ScenarioResult, extras: ReportExtras): Promise<void>;
}

export interface StagingHandles {
  /** Run a `docker compose` subcommand against the staging project. */
  composeRun(args: string): Promise<string>;
  restart(service: "redis-q" | "gateway" | "postgres"): Promise<void>;
  workerStart(env?: Record<string, string>): Promise<void>;
  workerKill(): Promise<void>;
  workerStopGraceful(): Promise<void>;
  pressureMount(mb: number): Promise<string>;
  pressureUnmount(): Promise<void>;
  /**
   * Additive (not in the plan's pinned list): the host worker is not a
   * container, so scenarios that assert "the worker did not crash-loop" read
   * the pidfile and signal 0 through this handle.
   */
  workerAlive(): Promise<boolean>;
}

export interface ChaosContext {
  staging: StagingHandles;
  env: Record<string, string>;
  /** Arms the NEXT-request script; await before sending the run. */
  mockArm(script: MockLlmScript): Promise<{ release(): void }>;
  liveCheckPoint(): Promise<LiveSnapshot>;
  report: ReportWriter;
}

export interface GateResult {
  ok: boolean;
  detail: string;
}

/**
 * A scenario is a four-phase pipeline. Only `inject` may touch the staging
 * composition; `gate` must be pure observation.
 */
export interface ChaosScenario<P = unknown> {
  name: ScenarioName;
  /** Human-readable statement of the vulnerable state the gate proves. */
  precondition: string;
  prepare(ctx: ChaosContext): Promise<P>;
  gate(ctx: ChaosContext, prepared: P): Promise<GateResult>;
  inject(ctx: ChaosContext, prepared: P): Promise<void>;
  verify(ctx: ChaosContext, prepared: P): Promise<Assertion[]>;
  /**
   * Called even when `prepare` throws (with `prepared === undefined`), so a
   * partial prepare cannot leave the staging worker stopped or the mock gate
   * held. Implementations MUST be idempotent and tolerate partial state.
   */
  cleanup?(ctx: ChaosContext, prepared: P | undefined): Promise<void>;
}

type AnyScenario = ChaosScenario<unknown>;

const REGISTRY: AnyScenario[] = [];

/** Scenario modules call this at import time (Task 7 adds its three). */
export function registerScenario<P>(scenario: ChaosScenario<P>): void {
  const existing = REGISTRY.findIndex((entry) => entry.name === scenario.name);
  if (existing >= 0) REGISTRY.splice(existing, 1);
  REGISTRY.push(scenario as unknown as AnyScenario);
}

export function registeredScenarios(): AnyScenario[] {
  return [...REGISTRY];
}

function errorText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * A scenario passes when at least one assertion ran and every assertion
 * passed. An injected scenario with an empty `verify()` cannot pass.
 */
export function scenarioAssertionsPass(assertions: Assertion[]): boolean {
  return assertions.length > 0 && assertions.every((assertion) => assertion.passed);
}

// ---------------------------------------------------------------------------
// Live-stack snapshot validation / diff (Task 1 command contract)
// ---------------------------------------------------------------------------

/** Problems that make a snapshot an invalid live-stack baseline. */
export function liveSnapshotProblems(snapshot: LiveSnapshot): string[] {
  const problems: string[] = [];
  if (snapshot.healthzStatus !== 200) {
    problems.push(`healthz expected 200, got ${snapshot.healthzStatus}`);
  }
  if (snapshot.containers.length === 0) {
    problems.push("no ovid-gateway-* containers found");
  }
  for (const container of snapshot.containers) {
    if (!/^Up\b/.test(container.status)) {
      problems.push(`container ${container.name} is not Up (${container.status})`);
    }
    if (container.startedAt === "") {
      problems.push(`container ${container.name} has no StartedAt`);
    }
  }
  return problems;
}

function diffLiveSnapshots(before: LiveSnapshot, after: LiveSnapshot): string[] {
  const problems: string[] = [];
  if (after.healthzStatus !== before.healthzStatus) {
    problems.push(
      `healthz changed from ${before.healthzStatus} to ${after.healthzStatus}`,
    );
  }
  if (after.healthzStatus !== 200) {
    problems.push(`healthz expected 200, got ${after.healthzStatus}`);
  }

  const afterByName = new Map(after.containers.map((c) => [c.name, c]));
  for (const container of before.containers) {
    const current = afterByName.get(container.name);
    if (current === undefined) {
      problems.push(`container ${container.name} disappeared`);
      continue;
    }
    if (!/^Up\b/.test(current.status)) {
      problems.push(`container ${container.name} is not Up (${current.status})`);
    }
    if (current.startedAt !== container.startedAt) {
      problems.push(
        `container ${container.name} StartedAt drifted (before ${container.startedAt}, after ${current.startedAt})`,
      );
    }
  }
  const beforeNames = new Set(before.containers.map((c) => c.name));
  for (const container of after.containers) {
    if (!beforeNames.has(container.name)) {
      problems.push(`unexpected container ${container.name} appeared`);
    }
  }
  return problems;
}

/**
 * The Task-1 live-unaffected contract as code. Throws with the diff on any
 * violation: healthz not 200, a container missing/not Up, or a StartedAt
 * change. The optional `capture` seam exists so the drift logic is unit-tested
 * without touching the live stack.
 */
export async function assertLiveUnaffected(
  before: LiveSnapshot,
  capture: () => Promise<LiveSnapshot> = () => captureLiveSnapshot(),
): Promise<void> {
  const beforeProblems = liveSnapshotProblems(before);
  if (beforeProblems.length > 0) {
    throw new Error(`live baseline is unhealthy: ${beforeProblems.join("; ")}`);
  }
  const after = await capture();
  const problems = diffLiveSnapshots(before, after);
  if (problems.length > 0) {
    throw new Error(`live stack changed during the scenario: ${problems.join("; ")}`);
  }
}

// ---------------------------------------------------------------------------
// Live capture (the Task 1 raw command contract)
// ---------------------------------------------------------------------------

function execText(command: string, args: string[], timeoutMs = 15_000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(command, args, { encoding: "utf8", timeout: timeoutMs }, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

export interface CaptureLiveOptions {
  healthzUrl?: string;
  dockerBinary?: string;
}

/**
 * `curl -sf https://api.ovidsi.com/healthz` (expect 200) +
 * `docker ps --filter name=ovid-gateway- …` + `docker inspect … StartedAt`.
 * Probe failures are recorded in `errors` rather than thrown so the snapshot
 * itself is always reportable; `liveSnapshotProblems` turns them into a gate
 * failure.
 */
export async function captureLiveSnapshot(
  opts: CaptureLiveOptions = {},
): Promise<LiveSnapshot> {
  const healthzUrl = opts.healthzUrl ?? "https://api.ovidsi.com/healthz";
  const docker = opts.dockerBinary ?? "docker";
  const errors: string[] = [];
  let healthzStatus = 0;
  try {
    const out = await execText("curl", [
      "-s",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      "--max-time",
      "10",
      healthzUrl,
    ]);
    healthzStatus = Number(out.trim());
    if (!Number.isFinite(healthzStatus)) healthzStatus = 0;
  } catch (err) {
    errors.push(`healthz probe failed: ${errorText(err)}`);
  }

  const containers: LiveContainer[] = [];
  try {
    const rows = await execText(docker, [
      "ps",
      "--filter",
      "name=ovid-gateway-",
      "--format",
      "{{.Names}} {{.Status}}",
    ]);
    for (const line of rows.split("\n")) {
      const trimmed = line.trim();
      if (trimmed === "") continue;
      const space = trimmed.indexOf(" ");
      const name = space === -1 ? trimmed : trimmed.slice(0, space);
      const status = space === -1 ? "" : trimmed.slice(space + 1);
      let startedAt = "";
      try {
        startedAt = (
          await execText(docker, ["inspect", name, "--format", "{{.State.StartedAt}}"])
        ).trim();
      } catch (err) {
        errors.push(`inspect ${name} failed: ${errorText(err)}`);
      }
      containers.push({ name, status, startedAt });
    }
  } catch (err) {
    errors.push(`docker ps failed: ${errorText(err)}`);
  }

  return {
    capturedAt: new Date().toISOString(),
    healthzStatus,
    containers,
    errors,
  };
}

// ---------------------------------------------------------------------------
// Scenario execution
// ---------------------------------------------------------------------------

/**
 * Run one registered scenario. Order:
 *   1. capture + validate the live baseline (refuse to inject when unhealthy),
 *   2. prepare scenario resources (clients, runs, gates),
 *   3. gate — no injection unless it passes,
 *   4. inject → verify,
 *   5. live-unaffected assertion (always, even on a failed gate),
 *   6. report block.
 */
export async function runChaosScenario(
  name: ScenarioName,
  ctx: ChaosContext,
  registry: AnyScenario[] = registeredScenarios(),
): Promise<ScenarioResult> {
  const scenario = registry.find((entry) => entry.name === name);
  if (scenario === undefined) {
    throw new Error(
      `runChaosScenario: scenario '${name}' is not registered (registered: ${
        registry.map((entry) => entry.name).join(", ") || "none"
      })`,
    );
  }

  const startedMs = Date.now();
  const assertions: Assertion[] = [];
  const result = (): ScenarioResult => ({
    name: scenario.name,
    passed: scenarioAssertionsPass(assertions),
    precondition: scenario.precondition,
    assertions,
    durationMs: Date.now() - startedMs,
  });

  let liveBefore: LiveSnapshot;
  try {
    liveBefore = await ctx.liveCheckPoint();
  } catch (err) {
    assertions.push({
      name: "live-unaffected-before",
      passed: false,
      detail: `live snapshot failed: ${errorText(err)}`,
    });
    const failed = result();
    await ctx.report.writeScenario(failed, { liveBefore: unhealthyUnknown() });
    return failed;
  }

  const baselineProblems = liveSnapshotProblems(liveBefore);
  if (baselineProblems.length > 0) {
    assertions.push({
      name: "live-unaffected-before",
      passed: false,
      detail: `refusing to inject: ${baselineProblems.join("; ")}`,
    });
    const failed = result();
    await ctx.report.writeScenario(failed, { liveBefore });
    return failed;
  }

  let prepared: unknown;
  try {
    prepared = await scenario.prepare(ctx);
  } catch (err) {
    assertions.push({
      name: "prepare",
      passed: false,
      detail: errorText(err),
    });
    // Partial state must be unwound too: a prepare that stopped the worker or
    // armed the gate and then threw would otherwise poison later scenarios.
    await cleanupScenario(scenario, ctx, undefined, assertions);
    return finalize(scenario, ctx, assertions, liveBefore, startedMs);
  }

  try {
    let gate: GateResult;
    try {
      gate = await scenario.gate(ctx, prepared);
    } catch (err) {
      gate = { ok: false, detail: `gate threw: ${errorText(err)}` };
    }
    assertions.push({ name: "precondition", passed: gate.ok, detail: gate.detail });

    if (gate.ok) {
      let injected = false;
      try {
        await scenario.inject(ctx, prepared);
        injected = true;
        assertions.push({
          name: "inject",
          passed: true,
          detail: "failure injected after the precondition gate passed",
        });
      } catch (err) {
        assertions.push({ name: "inject", passed: false, detail: errorText(err) });
      }

      if (injected) {
        try {
          assertions.push(...(await scenario.verify(ctx, prepared)));
        } catch (err) {
          assertions.push({ name: "verify", passed: false, detail: errorText(err) });
        }
      }
    }
  } finally {
    // Always, on every path (failed gate, inject throw, verify throw): restore
    // the staging composition to its pre-run state.
    await cleanupScenario(scenario, ctx, prepared, assertions);
  }

  return finalize(scenario, ctx, assertions, liveBefore, startedMs);
}

async function cleanupScenario(
  scenario: AnyScenario,
  ctx: ChaosContext,
  prepared: unknown,
  assertions: Assertion[],
): Promise<void> {
  if (scenario.cleanup === undefined) return;
  try {
    await scenario.cleanup(ctx, prepared);
  } catch (err) {
    assertions.push({ name: "cleanup", passed: false, detail: errorText(err) });
  }
}

function unhealthyUnknown(): LiveSnapshot {
  return {
    capturedAt: new Date().toISOString(),
    healthzStatus: 0,
    containers: [],
    errors: ["live snapshot unavailable"],
  };
}

async function finalize(
  scenario: AnyScenario,
  ctx: ChaosContext,
  assertions: Assertion[],
  liveBefore: LiveSnapshot,
  startedMs: number,
): Promise<ScenarioResult> {
  let liveAfter: LiveSnapshot | undefined;
  try {
    liveAfter = await ctx.liveCheckPoint();
    await assertLiveUnaffected(liveBefore, async () => liveAfter!);
    assertions.push({
      name: "live-unaffected-after",
      passed: true,
      detail: `healthz=200, ${liveAfter.containers.length} ovid-gateway-* container(s) Up, StartedAt unchanged`,
    });
  } catch (err) {
    assertions.push({
      name: "live-unaffected-after",
      passed: false,
      detail: errorText(err),
    });
  }

  const result: ScenarioResult = {
    name: scenario.name,
    passed: scenarioAssertionsPass(assertions),
    precondition: scenario.precondition,
    assertions,
    durationMs: Date.now() - startedMs,
  };
  await ctx.report.writeScenario(result, { liveBefore, liveAfter });
  return result;
}

// ---------------------------------------------------------------------------
// Markdown rendering (the CLI's ReportWriter uses this)
// ---------------------------------------------------------------------------

function renderSnapshot(snapshot: LiveSnapshot | undefined): string[] {
  if (snapshot === undefined) return ["_not captured_"];
  const lines = [
    `- capturedAt: ${snapshot.capturedAt}`,
    `- healthz: ${snapshot.healthzStatus}`,
    `- containers: ${snapshot.containers.length}`,
  ];
  for (const container of snapshot.containers) {
    lines.push(`  - \`${container.name}\` — ${container.status} — StartedAt ${container.startedAt}`);
  }
  if (snapshot.errors !== undefined && snapshot.errors.length > 0) {
    for (const error of snapshot.errors) lines.push(`  - probe error: ${error}`);
  }
  return lines;
}

export function renderScenarioMarkdown(
  result: ScenarioResult,
  extras: ReportExtras,
): string {
  const rows = result.assertions.map(
    (assertion) =>
      `| \`${assertion.name}\` | ${assertion.passed ? "PASS" : "FAIL"} | ${assertion.detail.replace(/\|/g, "\\|")} |`,
  );
  const notes =
    extras.notes === undefined || extras.notes.length === 0
      ? []
      : ["", "### Notes", "", ...extras.notes.map((note) => `- ${note}`)];
  return [
    `## ${result.name} — ${result.passed ? "PASS" : "FAIL"}`,
    "",
    `- precondition: ${result.precondition}`,
    `- durationMs: ${result.durationMs}`,
    "",
    "### Assertions",
    "",
    "| Assertion | Result | Detail |",
    "|---|---|---|",
    ...rows,
    "",
    "### Live stack (before)",
    "",
    ...renderSnapshot(extras.liveBefore),
    "",
    "### Live stack (after)",
    "",
    ...renderSnapshot(extras.liveAfter),
    ...notes,
    "",
  ].join("\n");
}
