import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import type { SandboxConfig } from "./config.js";

/**
 * True only on the sandbox host itself, opt-in: the operator sets
 * OVID_SANDBOX_HOST_TESTS=1 on a root-provisioned dev/staging VM. Host suites
 * gate themselves on this (describe.skipIf) so `pnpm test` stays green
 * everywhere else.
 */
export function hostTestsAvailable(): boolean {
  return process.env.OVID_SANDBOX_HOST_TESTS === "1" && process.getuid?.() === 0;
}

// One probe per process: bwrap checks can be slow, and the answer cannot
// change within a run. null = not probed yet.
let jailProbeResult: boolean | null = null;

/**
 * Whether the configured bwrap can actually jail a process on this host:
 * the binary exists AND a trivial sandboxed spawn succeeded. Host suites use
 * this (together with hostTestsAvailable) in describe.skipIf to skip when the
 * mechanism is unavailable (e.g. no userns, wrong kernel config).
 */
export function jailMechanismAvailable(cfg: SandboxConfig): boolean {
  if (jailProbeResult === null) {
    jailProbeResult =
      existsSync(cfg.bwrapPath) &&
      spawnSync(
        cfg.bwrapPath,
        ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "/bin/true"],
        { timeout: 5_000 },
      ).status === 0;
  }
  return jailProbeResult;
}
