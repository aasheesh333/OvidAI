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
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { afterAll, describe, expect, it } from "vitest";

const HERE = dirname(fileURLToPath(import.meta.url));
const CLOUD_DIR = resolve(HERE, "../../..");
const SCRIPT = join(CLOUD_DIR, "scripts/staging.sh");
const EXAMPLE_ENV = join(CLOUD_DIR, "deploy/.env.staging.example");

const EXAMPLE_BODY = readFileSync(EXAMPLE_ENV, "utf8");
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

/** Write the shipped example + `overrides` (last assignment wins) and run guard. */
function runGuard(overrides: Record<string, string> = {}): GuardResult {
  const dir = mkdtempSync(join(tmpdir(), "ovid-staging-guard-"));
  TEMP_DIRS.push(dir);
  const file = join(dir, ".env.staging");
  const extra = Object.entries(overrides)
    .map(([key, value]) => `${key}=${value}`)
    .join("\n");
  writeFileSync(file, `${EXAMPLE_BODY}\n${extra}\n`, "utf8");

  try {
    const stdout = execFileSync("bash", [SCRIPT, "guard", "--env-file", file], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
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
});
