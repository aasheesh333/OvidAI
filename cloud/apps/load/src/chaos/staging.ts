import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { appendFile, mkdir, readFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { dirname, resolve } from "node:path";
import {
  captureLiveSnapshot,
  renderScenarioMarkdown,
  type ChaosContext,
  type LiveSnapshot,
  type ReportExtras,
  type ReportWriter,
  type ScenarioResult,
  type StagingHandles,
} from "./runner.js";
import { startMockLlmServer, type MockLlmServer } from "../mockServer.js";

/**
 * The staging implementation of the chaos handles.
 *
 * Everything mutating goes through `cloud/scripts/staging.sh` (Task 1's
 * supported entry point) or the staging compose project; the chaos runner
 * never composes the stack itself. The one exception is the gated mock: the
 * long-running `staging.sh mock-start` process has no control channel, so
 * when a scenario needs `mockArm()` this module stops that process (the
 * existing `mock-stop` subcommand) and runs the SAME `startMockLlmServer` in
 * this process on 0.0.0.0:14000, where `arm()` is directly reachable. On
 * close the displaced staging mock is restored with `mock-start`.
 */

export interface FileReportWriterOptions {
  header?: string;
}

export function createFileReportWriter(
  path: string,
  opts: FileReportWriterOptions = {},
): ReportWriter & { path: string } {
  let initialised = false;
  async function append(markdown: string): Promise<void> {
    await mkdir(dirname(resolve(path)), { recursive: true });
    const text = markdown.endsWith("\n") ? markdown : `${markdown}\n`;
    if (!initialised) {
      initialised = true;
      let existing = "";
      try {
        existing = await readFile(resolve(path), "utf8");
      } catch {
        existing = "";
      }
      if (existing === "" && opts.header !== undefined) {
        await appendFile(resolve(path), `${opts.header}\n`, "utf8");
      }
    }
    await appendFile(resolve(path), text, "utf8");
  }

  return {
    path,
    append,
    async writeScenario(result: ScenarioResult, extras: ReportExtras): Promise<void> {
      await append(renderScenarioMarkdown(result, extras));
    },
  };
}

export function resolveStagingScript(explicit?: string): string {
  const candidates = [
    explicit,
    process.env.STAGING_SCRIPT,
    resolve(process.cwd(), "scripts/staging.sh"),
    resolve(process.cwd(), "cloud/scripts/staging.sh"),
  ].filter((candidate): candidate is string => typeof candidate === "string");
  const found = candidates.find((candidate) => existsSync(candidate));
  if (found === undefined) {
    throw new Error(
      "chaos: staging.sh not found — run from cloud/ or set STAGING_SCRIPT",
    );
  }
  return found;
}

export function parseEnv(text: string): Record<string, string> {
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

function execText(command: string, args: string[], timeoutMs = 60_000): Promise<string> {
  return new Promise((resolvePromise, reject) => {
    execFile(command, args, { encoding: "utf8", timeout: timeoutMs }, (err, stdout) => {
      if (err) reject(err);
      else resolvePromise(stdout);
    });
  });
}

function splitArgs(args: string): string[] {
  return args.trim() === "" ? [] : args.trim().split(/\s+/);
}

function pidAlive(pidfile: string): boolean {
  try {
    const text = requirePidfileSync(pidfile);
    if (text === null) return false;
    process.kill(Number(text), 0);
    return true;
  } catch {
    return false;
  }
}

function requirePidfileSync(path: string): string | null {
  try {
    const text = readFileSync(path, "utf8").trim();
    return text === "" ? null : text;
  } catch {
    return null;
  }
}

function portInUse(port: number): Promise<boolean> {
  return new Promise((resolvePromise) => {
    const socket = createConnection({ host: "127.0.0.1", port });
    const done = (inUse: boolean): void => {
      socket.destroy();
      resolvePromise(inUse);
    };
    socket.setTimeout(500);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
  });
}

async function waitForPortFree(port: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!(await portInUse(port))) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 200));
  }
  throw new Error(
    `chaos: port ${port} is still in use — cannot start the controllable gated mock ` +
      "(stop the process holding it, or run `staging.sh mock-stop`)",
  );
}

export interface StagingContextOptions {
  scriptPath?: string;
  /** Defaults to `<cloud>/deploy/.env.staging` (staging.sh's own default). */
  envFile?: string;
  composeFile?: string;
  report?: ReportWriter;
  reportPath?: string;
  reportHeader?: string;
  captureLive?: () => Promise<LiveSnapshot>;
  mockPort?: number;
  mockBindHost?: string;
}

export interface StagingContext extends ChaosContext {
  close(): Promise<void>;
}

export async function createStagingContext(
  opts: StagingContextOptions = {},
): Promise<StagingContext> {
  const script = resolveStagingScript(opts.scriptPath);
  const cloudDir = resolve(dirname(script), "..");
  const envFile = opts.envFile ?? process.env.STAGING_ENV_FILE ?? resolve(cloudDir, "deploy/.env.staging");
  const composeFile =
    opts.composeFile ?? resolve(cloudDir, "deploy/docker-compose.staging.yml");
  const mockPort = opts.mockPort ?? 14000;
  const mockBindHost = opts.mockBindHost ?? "0.0.0.0";

  const env = parseEnv(await execText("bash", [script, "env"]));
  for (const required of ["STAGING_GATEWAY_URL", "STAGING_REDIS_Q_URL"]) {
    if (env[required] === undefined) {
      throw new Error(`chaos: staging.sh env did not print ${required}`);
    }
  }

  const report =
    opts.report ??
    createFileReportWriter(
      opts.reportPath ?? resolve(process.cwd(), `reports/chaos-${utcDate()}.md`),
      { header: opts.reportHeader },
    );

  const composeRun = async (args: string): Promise<string> =>
    execText("docker", [
      "compose",
      "--env-file",
      envFile,
      "-p",
      "ovid-cloud-staging",
      "-f",
      composeFile,
      ...splitArgs(args),
    ]);

  const workerPidfile =
    env.STAGING_WORKER_PIDFILE ?? "/tmp/opencode/ovid-staging-worker.pid";
  const mockPidfile =
    env.STAGING_MOCK_PIDFILE ?? "/tmp/opencode/ovid-staging-mock.pid";

  const staging: StagingHandles = {
    composeRun,
    async restart(service) {
      await composeRun(`restart ${service}`);
    },
    async workerStart(overrides = {}) {
      const args = ["worker-start"];
      for (const [key, value] of Object.entries(overrides)) {
        args.push("--env", `${key}=${value}`);
      }
      await execText("bash", [script, ...args]);
    },
    async workerKill() {
      await execText("bash", [script, "worker-stop", "kill"]);
    },
    async workerStopGraceful() {
      await execText("bash", [script, "worker-stop", "graceful"]);
    },
    async pressureMount(mb) {
      return execText("bash", [script, "pressure-mount", String(mb)]);
    },
    async pressureUnmount() {
      await execText("bash", [script, "pressure-unmount"]);
    },
    async workerAlive() {
      return pidAlive(workerPidfile);
    },
  };

  let mock: MockLlmServer | undefined;
  let displacedStagingMock = false;

  async function ensureMock(): Promise<MockLlmServer> {
    if (mock !== undefined) return mock;
    // The staging mock started by `staging.sh mock-start` has no arm()
    // channel. Stop it (existing subcommand) and own the port ourselves.
    displacedStagingMock = pidAlive(mockPidfile);
    try {
      await execText("bash", [script, "mock-stop"]);
    } catch {
      // no pidfile / already stopped — the port check below decides
    }
    await waitForPortFree(mockPort, 10_000);
    mock = await startMockLlmServer({ port: mockPort, bindHost: mockBindHost });
    return mock;
  }

  // Start eagerly: `mockArm` is synchronous by contract, and a gated run's
  // first LLM request must observe the armed script (never a race).
  await ensureMock();

  return {
    staging,
    env,
    mockArm(script_) {
      if (mock === undefined) {
        throw new Error("chaos: gated mock is not running");
      }
      return mock.arm(script_);
    },
    liveCheckPoint: opts.captureLive ?? (() => captureLiveSnapshot()),
    report,
    async close() {
      if (mock !== undefined) {
        await mock.close().catch(() => {});
        mock = undefined;
      }
      if (displacedStagingMock) {
        displacedStagingMock = false;
        // Restore the staging stack's own mock for later gates/runs.
        await execText("bash", [script, "mock-start"]).catch(() => {});
      }
    },
  };
}

export function utcDate(): string {
  const now = new Date();
  const month = String(now.getUTCMonth() + 1).padStart(2, "0");
  const day = String(now.getUTCDate()).padStart(2, "0");
  return `${now.getUTCFullYear()}${month}${day}`;
}
