/**
 * P10 Task 1 — staging isolation guard.
 *
 * These tests exercise `cloud/scripts/staging.sh guard` exactly as an
 * operator/load harness would: write a temporary env file, spawn the script,
 * and assert the exit code plus the variable named on stderr. No Docker,
 * no network, no dev services — the guard is pure env validation.
 *
 * The shipped `.env.staging.example` is the base fixture for every rejection
 * case, so a rejection can only come from the single overridden value.
 */
import { execFileSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { afterAll, describe, expect, it } from "vitest";

const HERE = dirname(fileURLToPath(import.meta.url));
const CLOUD_DIR = resolve(HERE, "../../..");
const SCRIPT = join(CLOUD_DIR, "scripts/staging.sh");
const EXAMPLE_ENV = join(CLOUD_DIR, "deploy/.env.staging.example");
const MINT_ENV = join(CLOUD_DIR, "deploy/.env.staging.mint");
const MINT_EXAMPLE_ENV = join(CLOUD_DIR, "deploy/.env.staging.mint.example");

const EXAMPLE_BODY = readFileSync(EXAMPLE_ENV, "utf8");
const MINT_EXAMPLE_BODY = readFileSync(MINT_EXAMPLE_ENV, "utf8");
const TEMP_DIRS: string[] = [];

afterAll(() => {
  for (const dir of TEMP_DIRS) {
    rmSync(dir, { recursive: true, force: true });
  }
});

interface GuardResult {
  status: number;
  stdout: string;
  stderr: string;
}

interface GuardOptions {
  overrides?: Record<string, string>;
  /** Example-file lines whose `KEY=` assignment is deleted before running. */
  remove?: string[];
  /** Raw lines appended verbatim (for syntax/execution probes). */
  extraLines?: string[];
  /** Extra process environment (e.g. STAGING_ENV_FILE). */
  env?: NodeJS.ProcessEnv;
}

function runScript(command: string, args: string[], env?: NodeJS.ProcessEnv): GuardResult {
  try {
    const stdout = execFileSync("bash", [SCRIPT, command, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...env },
    });
    return { status: 0, stdout, stderr: "" };
  } catch (error) {
    const err = error as { status?: number; stdout?: string; stderr?: string };
    return {
      status: err.status ?? -1,
      stdout: err.stdout ?? "",
      stderr: err.stderr ?? "",
    };
  }
}

function runGuardFile(file: string, env?: NodeJS.ProcessEnv): GuardResult {
  return runScript("guard", ["--env-file", file], env);
}

/**
 * Write the shipped example (optionally with lines removed) + `overrides`
 * (last assignment wins) + raw `extraLines` and run guard. `remove` is how the
 * omission probes (H1) prove a variable cannot silently fall back to a live
 * default.
 */
function runGuardWith(options: GuardOptions = {}): GuardResult {
  const { overrides = {}, remove = [], extraLines = [], env } = options;
  const dir = mkdtempSync(join(tmpdir(), "ovid-staging-guard-"));
  TEMP_DIRS.push(dir);
  const file = join(dir, ".env.staging");
  const body = EXAMPLE_BODY.split("\n")
    .filter((line) => !remove.some((key) => line.startsWith(`${key}=`)))
    .join("\n");
  const extra = Object.entries(overrides)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  writeFileSync(file, `${body}\n${extra}\n${extraLines.join("\n")}\n`, "utf8");
  return runGuardFile(file, env);
}

/** Write the shipped example + `overrides` (last assignment wins) and run guard. */
function runGuard(overrides: Record<string, string> = {}): GuardResult {
  return runGuardWith({ overrides });
}

function runWorkerStart(args: string[]): GuardResult {
  return runScript("worker-start", args);
}

function pathExists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

function expectRejected(result: GuardResult, variable: string): void {
  expect(result.status).toBe(2);
  expect(result.stderr).toContain("GUARD FAIL");
  expect(result.stderr).toContain(variable);
}

describe("staging.sh guard — production isolation", () => {
  it("accepts the shipped .env.staging.example", () => {
    const result = runGuard();
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("guard OK");
  });

  it("rejects a prod DATABASE_URL", () => {
    const result = runGuard({
      DATABASE_URL:
        "postgres://ovid_cloud:x@ovid-gateway-postgres-1:5432/ovid_cloud",
    });
    expectRejected(result, "DATABASE_URL");
  });

  it("rejects a live redis-q url", () => {
    const result = runGuard({
      REDIS_Q_URL: "redis://:staging@ovid-gateway-redis-1:6379",
    });
    expectRejected(result, "REDIS_Q_URL");
  });

  it("rejects the prod uid base or workspace root", () => {
    expectRejected(runGuard({ OVID_SANDBOX_UID_BASE: "200000" }), "OVID_SANDBOX_UID_BASE");
    expectRejected(runGuard({ OVID_WORKSPACES_ROOT: "/workspaces" }), "OVID_WORKSPACES_ROOT");
  });

  it("rejects a non-loopback staging publish address", () => {
    expectRejected(
      runGuard({ STAGING_BIND_ADDRESS: "0.0.0.0" }),
      "STAGING_BIND_ADDRESS",
    );
  });

  it("rejects a live compose project override", () => {
    expectRejected(
      runGuard({ COMPOSE_PROJECT_NAME: "ovid-gateway" }),
      "COMPOSE_PROJECT_NAME",
    );
  });

  it("rejects prod mint wiring", () => {
    // live redis-mint port
    expectRejected(
      runGuard({ REDIS_MINT_URL: "redis://:staging@127.0.0.1:6392/2" }),
      "REDIS_MINT_URL",
    );
    // live internal-mint listener (P9 public port, not the admin surface)
    expectRejected(
      runGuard({ OVID_INTERNAL_MINT_URL: "http://127.0.0.1:8092" }),
      "OVID_INTERNAL_MINT_URL",
    );
    // the pre-P9 surface deleted by P9 Task 9 must not reappear
    expectRejected(
      runGuard({ MINT_BASE_URL: "http://127.0.0.1:4000" }),
      "MINT_BASE_URL",
    );
  });

  // ── H1: OVID_CGROUP_BASE is required and EXACT ──────────────────────────
  it("H1: rejects an env with OVID_CGROUP_BASE omitted (no live-default fallback)", () => {
    // Omitting the variable used to pass; config.ts then fell back to the
    // LIVE `ovid-sandboxes.slice/ovid-worker.service`. Mutation-load-bearing:
    // removing require_var from the guard makes this exit 0.
    expectRejected(
      runGuardWith({ remove: ["OVID_CGROUP_BASE"] }),
      "OVID_CGROUP_BASE",
    );
  });

  it("H1: rejects a sibling cgroup path under the staging slice (exact, not prefix)", () => {
    // The old prefix check accepted any `ovid-sandboxes-staging.slice/*`.
    expectRejected(
      runGuard({
        OVID_CGROUP_BASE: "ovid-sandboxes-staging.slice/other.service",
      }),
      "OVID_CGROUP_BASE",
    );
    // The live default itself must never be accepted.
    expectRejected(
      runGuard({
        OVID_CGROUP_BASE: "ovid-sandboxes.slice/ovid-worker.service",
      }),
      "OVID_CGROUP_BASE",
    );
  });

  // ── H2: normalize first; reject `..` traversal ──────────────────────────
  it("H2: rejects the exact cgroup traversal string into the live worker", () => {
    // posixpath.normpath(...) == ovid-sandboxes.slice/ovid-worker.service
    // (the LIVE path); the old prefix check accepted it.
    expectRejected(
      runGuard({
        OVID_CGROUP_BASE:
          "ovid-sandboxes-staging.slice/../ovid-sandboxes.slice/ovid-worker.service",
      }),
      "OVID_CGROUP_BASE",
    );
  });

  it("H2: rejects the exact fs-storage traversal string into live user storage", () => {
    // normpath(...) == /workspaces/users/storage (the LIVE storage root);
    // the old prefix check accepted it.
    expectRejected(
      runGuard({
        OVID_FS_STORAGE_ROOT:
          "/workspaces-staging/../../workspaces/users/storage",
      }),
      "OVID_FS_STORAGE_ROOT",
    );
    // Same rule for the workspace root itself.
    expectRejected(
      runGuard({
        OVID_WORKSPACES_ROOT: "/workspaces-staging/../workspaces/users",
      }),
      "OVID_WORKSPACES_ROOT",
    );
  });

  it("H2: accepts a path whose normalized form is the staging literal", () => {
    // Normalization is the gate, not byte equality: `//` and `/./` collapse
    // to the pinned staging root and remain safe.
    const result = runGuard({
      OVID_FS_STORAGE_ROOT: "/workspaces-staging//./storage",
    });
    expect(result.status).toBe(0);
  });

  // ── H3: OVID_BROWSER_STATE_DIR is guarded ───────────────────────────────
  it("H3: rejects the live browser-state dir, traversal, and omission", () => {
    expectRejected(
      runGuard({ OVID_BROWSER_STATE_DIR: "/opt/ovid-cloud/browser-states" }),
      "OVID_BROWSER_STATE_DIR",
    );
    expectRejected(
      runGuard({
        OVID_BROWSER_STATE_DIR:
          "/workspaces-staging/../workspaces/users/browser-states",
      }),
      "OVID_BROWSER_STATE_DIR",
    );
    expectRejected(
      runGuardWith({ remove: ["OVID_BROWSER_STATE_DIR"] }),
      "OVID_BROWSER_STATE_DIR",
    );
  });

  // ── M3: compose hardcodes env_file; reject non-default overrides ────────
  it("M3: rejects a non-default STAGING_ENV_FILE override", () => {
    // `--env-file` only controls interpolation; service `env_file:` is
    // hardcoded, so a validated override would not be the loaded file.
    expectRejected(
      runGuardWith({ env: { STAGING_ENV_FILE: "/tmp/other-staging.env" } }),
      "STAGING_ENV_FILE",
    );
  });

  it("M3: rejects a non-default STAGING_MINT_ENV_FILE override", () => {
    expectRejected(
      runGuardWith({
        env: { STAGING_MINT_ENV_FILE: "/tmp/other-staging.mint.env" },
      }),
      "STAGING_MINT_ENV_FILE",
    );
  });
});

describe("NEW-1: worker-start --env overrides are validated", () => {
  it("rejects a live-path override (the H1/H2/H3 re-opening)", () => {
    expectRejected(
      runWorkerStart([
        "--env-file",
        EXAMPLE_ENV,
        "--env",
        "OVID_CGROUP_BASE=ovid-sandboxes.slice/ovid-worker.service",
      ]),
      "OVID_CGROUP_BASE",
    );
    expectRejected(
      runWorkerStart([
        "--env-file",
        EXAMPLE_ENV,
        "--env",
        "OVID_WORKSPACES_ROOT=/workspaces/users",
      ]),
      "OVID_WORKSPACES_ROOT",
    );
  });

  it("rejects an empty override (it resolves to a live default)", () => {
    expectRejected(
      runWorkerStart(["--env-file", EXAMPLE_ENV, "--env", "OVID_RUN_STALE_MS="]),
      "OVID_RUN_STALE_MS",
    );
  });

  it("rejects an unknown override name", () => {
    expectRejected(
      runWorkerStart(["--env-file", EXAMPLE_ENV, "--env", "EVIL_KNOB=1"]),
      "EVIL_KNOB",
    );
  });

  it("rejects a newline in an override", () => {
    expectRejected(
      runWorkerStart([
        "--env-file",
        EXAMPLE_ENV,
        "--env",
        "OVID_RUN_STALE_MS=15000\n/workspaces/users",
      ]),
      "OVID_RUN_STALE_MS",
    );
  });

  it("still runs the shared value validation for an allowlisted knob", () => {
    // The knob is allowlisted, but a non-numeric value must still fail the
    // shared validator (which runs on the effective env, overrides included).
    expectRejected(
      runWorkerStart([
        "--env-file",
        EXAMPLE_ENV,
        "--env",
        "OVID_RUN_STALE_MS=soon",
      ]),
      "OVID_RUN_STALE_MS",
    );
  });

  it("accepts a lowered stale threshold via --env (the chaos harness path)", () => {
    // workerKill needs a 15 s threshold to observe a stranded run quickly.
    // The file-level floor (>= 60 s) deliberately does NOT apply to an
    // explicit override; otherwise that scenario could not run at all.
    //
    // This call really launches the staging worker (worker-start's whole
    // point), so it MUST be stopped again — a leftover worker holds :18093
    // and makes every later worker-start in this suite fail with "already
    // running", which reads as a guard bug and is not one.
    runScript("worker-stop", ["kill"]);
    try {
      const result = runWorkerStart([
        "--env-file",
        EXAMPLE_ENV,
        "--env",
        "OVID_RUN_STALE_MS=15000",
      ]);
      expect(result.stderr).not.toContain("GUARD FAIL: OVID_RUN_STALE_MS");
    } finally {
      runScript("worker-stop", ["kill"]);
    }
  });
});

describe("OVID_RUN_STALE_MS: the file floor that broke the first full100 run", () => {
  it("rejects a 15 s file value — it sweeps healthy long runs as run_lost", () => {
    expectRejected(runGuard({ OVID_RUN_STALE_MS: "15000" }), "OVID_RUN_STALE_MS");
  });

  it("accepts the production-like 600 s default", () => {
    expect(runGuard({ OVID_RUN_STALE_MS: "600000" }).status).toBe(0);
  });
});

describe("NEW-2: staging URLs are parsed and ports pinned", () => {
  it("rejects URL userinfo that hides a non-loopback host", () => {
    expectRejected(
      runGuard({
        STAGING_GATEWAY_URL: "http://127.0.0.1:8080@api.ovidsi.com",
      }),
      "STAGING_GATEWAY_URL",
    );
  });

  it("rejects live/wrong gateway and mock ports", () => {
    expectRejected(
      runGuard({ STAGING_GATEWAY_URL: "http://127.0.0.1:8080" }),
      "STAGING_GATEWAY_URL",
    );
    expectRejected(
      runGuard({ STAGING_GATEWAY_URL: "http://127.0.0.1:4000" }),
      "STAGING_GATEWAY_URL",
    );
    expectRejected(
      runGuard({ STAGING_MOCK_LLM_URL: "http://127.0.0.1:4000" }),
      "STAGING_MOCK_LLM_URL",
    );
  });

  it("accepts the exact staging URLs", () => {
    const result = runGuard({
      STAGING_GATEWAY_URL: "http://127.0.0.1:18082",
      STAGING_MOCK_LLM_URL: "http://127.0.0.1:14000",
    });
    expect(result.status).toBe(0);
  });
});

describe("NEW-3: unguarded live-service variables are pinned", () => {
  it("rejects a live REDIS_C_URL and accepts the staging redis-q", () => {
    expectRejected(
      runGuard({ REDIS_C_URL: "redis://:staging@127.0.0.1:6390" }),
      "REDIS_C_URL",
    );
    expect(
      runGuard({ REDIS_C_URL: "redis://:staging@127.0.0.1:16379" }).status,
    ).toBe(0);
  });

  it("rejects a live LiteLLM anthropic base and accepts the mock", () => {
    expectRejected(
      runGuard({ OVID_ANTHROPIC_BASE: "http://127.0.0.1:4000" }),
      "OVID_ANTHROPIC_BASE",
    );
    expect(
      runGuard({ OVID_ANTHROPIC_BASE: "http://172.17.0.1:14000" }).status,
    ).toBe(0);
  });

  it("requires a browser egress uid outside both sandbox blocks", () => {
    expectRejected(
      runGuard({ OVID_BROWSER_EGRESS_UID: "200000-200099" }),
      "OVID_BROWSER_EGRESS_UID",
    );
    expectRejected(
      runGuard({ OVID_BROWSER_EGRESS_UID: "220000-229999" }),
      "OVID_BROWSER_EGRESS_UID",
    );
    expect(
      runGuard({ OVID_BROWSER_EGRESS_UID: "230000-230099" }).status,
    ).toBe(0);
  });
});

describe("NEW-4: the env file is parsed, never sourced", () => {
  it("does not execute command substitution", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovid-staging-canary-"));
    TEMP_DIRS.push(dir);
    const canary = join(dir, "pwned");
    const result = runGuardWith({
      extraLines: [`PROBE_PWN=$(touch ${canary})`],
    });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("PROBE_PWN");
    expect(existsSync(canary)).toBe(false);
  });

  it("rejects `exit 0` instead of silently passing the guard", () => {
    const result = runGuardWith({ extraLines: ["exit 0"] });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("not a KEY=VALUE assignment");
  });

  it("rejects a function override instead of letting it defeat the guard", () => {
    const result = runGuardWith({
      extraLines: [
        "require_exact_path() { :; }",
        "OVID_CGROUP_BASE=ovid-sandboxes.slice/ovid-worker.service",
      ],
    });
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("not a KEY=VALUE assignment");
  });
});

describe("NEW-5: symlinked staging paths are rejected", () => {
  it("rejects a symlinked /workspaces-staging root", () => {
    // The probe needs root and an absent path; otherwise it cannot run.
    if (typeof process.getuid !== "function" || process.getuid() !== 0) return;
    if (pathExists("/workspaces-staging")) return;

    const target = mkdtempSync(join(tmpdir(), "ovid-staging-symlink-"));
    TEMP_DIRS.push(target);
    try {
      symlinkSync(target, "/workspaces-staging");
      expectRejected(runGuard(), "OVID_WORKSPACES_ROOT");
    } finally {
      try {
        unlinkSync("/workspaces-staging");
      } catch {
        // already removed
      }
    }
  });
});

describe("NEW-6: multi-line values are rejected", () => {
  it("rejects a newline embedded in an env-file value", () => {
    const dir = mkdtempSync(join(tmpdir(), "ovid-staging-newline-"));
    TEMP_DIRS.push(dir);
    const file = join(dir, ".env.staging");
    writeFileSync(
      file,
      `${EXAMPLE_BODY}\nOVID_FS_STORAGE_ROOT="/workspaces-staging/storage\n/workspaces/users/storage"\n`,
      "utf8",
    );
    const result = runGuardFile(file);
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("OVID_FS_STORAGE_ROOT");
  });

  it("rejects a newline in a worker-start override", () => {
    expectRejected(
      runWorkerStart([
        "--env-file",
        EXAMPLE_ENV,
        "--env",
        "OVID_RUN_STALE_MS=15000\n/workspaces/users",
      ]),
      "OVID_RUN_STALE_MS",
    );
  });
});

describe("NEW-7: root-written log/pid files stay under /tmp/opencode", () => {
  it("rejects /opt worker and mock log/pidfile paths", () => {
    expectRejected(
      runGuard({ STAGING_WORKER_LOG: "/opt/ovid-gateway/staging-worker.log" }),
      "STAGING_WORKER_LOG",
    );
    expectRejected(
      runGuard({
        STAGING_WORKER_PIDFILE: "/opt/ovid-gateway/staging-worker.pid",
      }),
      "STAGING_WORKER_PIDFILE",
    );
    expectRejected(
      runGuard({ STAGING_MOCK_LOG: "/var/lib/ovid/staging-mock.log" }),
      "STAGING_MOCK_LOG",
    );
    expectRejected(
      runGuard({ STAGING_MOCK_PIDFILE: "/opt/ovid-gateway/staging-mock.pid" }),
      "STAGING_MOCK_PIDFILE",
    );
  });

  it("accepts the shipped /tmp/opencode paths", () => {
    expect(runGuard().status).toBe(0);
  });
});

describe("NEW-8: guard validates .env.staging.mint when present", () => {
  it("rejects a prod-valued mint env and accepts the shipped mint example", () => {
    // Do not clobber a real operator file.
    if (existsSync(MINT_ENV)) return;
    try {
      writeFileSync(
        MINT_ENV,
        `${MINT_EXAMPLE_BODY}\nDATABASE_URL=postgres://postgres:staging@postgres:5432/ovid_cloud\n`,
        "utf8",
      );
      expectRejected(runGuard(), "DATABASE_URL");

      writeFileSync(MINT_ENV, MINT_EXAMPLE_BODY, "utf8");
      expect(runGuard().status).toBe(0);
    } finally {
      try {
        unlinkSync(MINT_ENV);
      } catch {
        // already removed
      }
    }
  });
});
