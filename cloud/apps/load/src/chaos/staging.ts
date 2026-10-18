import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { appendFile, mkdir, readFile } from "node:fs/promises";
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
import type { MockLlmScript } from "../mockServer.js";

/**
 * The staging implementation of the chaos handles.
 *
 * Everything mutating goes through `cloud/scripts/staging.sh` (Task 1's
 * supported entry point) or the staging compose project; the chaos runner
 * never composes the stack itself.
 *
 * The gated mock is driven over its DOCUMENTED HTTP control surface
 * (`POST /_control/arm`, `POST /_control/release`) rather than by displacing
 * the process. Both staging shapes — the compose `mock-llm` service and the
 * `staging.sh mock-start` host process — run the same server and expose it.
 * Displacing the service (the previous approach) broke key provisioning: the
 * mint reaches LiteLLM at `mock-llm:14000` inside the compose network, so a
 * stopped service made every NEW account fail with `key_not_minted`.
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

export interface StagingContextOptions {
  scriptPath?: string;
  /** Defaults to `<cloud>/deploy/.env.staging` (staging.sh's own default). */
  envFile?: string;
  composeFile?: string;
  report?: ReportWriter;
  reportPath?: string;
  reportHeader?: string;
  captureLive?: () => Promise<LiveSnapshot>;
  /** Base URL of the staging mock; defaults to STAGING_MOCK_LLM_URL. */
  mockBaseUrl?: string;
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

  let closed = false;
  // The mock is armed over HTTP; nothing here owns or displaces it.
  const mockBaseUrl = (
    opts.mockBaseUrl ??
    env.STAGING_MOCK_LLM_URL ??
    "http://127.0.0.1:14000"
  ).replace(/\/+$/, "");

  /**
   * Arm the next-request script through the mock's control surface. ASYNC on
   * purpose: the caller must await it before sending the run, because the
   * run's first LLM request snapshots the armed script (never a race).
   */
  async function mockArm(script_: MockLlmScript): Promise<{ release(): void }> {
    const res = await fetch(`${mockBaseUrl}/_control/arm`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(script_),
    });
    if (!res.ok) {
      throw new Error(`chaos: mock arm failed (HTTP ${res.status})`);
    }
    const body = (await res.json()) as { gateId?: unknown };
    const gateId = typeof body.gateId === "string" ? body.gateId : null;
    if (gateId === null) throw new Error("chaos: mock arm returned no gateId");
    return {
      release() {
        // Fire-and-forget: every scenario waits on the RUN's observable
        // progress after releasing, so a release landing a few ms late
        // cannot change an assertion (and a failed release just leaves the
        // gate armed until the next scenario arms again).
        void fetch(`${mockBaseUrl}/_control/release`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ gateId }),
        }).catch(() => {});
      },
    };
  }

  return {
    staging,
    env,
    mockArm,
    liveCheckPoint: opts.captureLive ?? (() => captureLiveSnapshot()),
    report,
    async close() {
      // Idempotent: the CLI's finally and a SIGINT handler may both call it.
      // Nothing to restore: the staging mock was never displaced.
      closed = true;
    },
  };
}

export function utcDate(): string {
  const now = new Date();
  const month = String(now.getUTCMonth() + 1).padStart(2, "0");
  const day = String(now.getUTCDate()).padStart(2, "0");
  return `${now.getUTCFullYear()}${month}${day}`;
}
