import type { CgroupManager } from "./cgroups.js";
import type { SandboxConfig } from "./config.js";
import type { JailLauncher } from "./launcher.js";

/**
 * Everything a one-shot (Task 7) or long-running (Task 9) jail execution
 * needs. Assembled by {@link makeJailContext}; Tasks 8/9 mint one context
 * per sandbox after allocating its uid and workspace.
 */
export interface JailContext {
  config: SandboxConfig;
  launcher: JailLauncher;
  cgroups: CgroupManager;
  /** The sandbox uid this context jails as (also the gid — no groups). */
  uid: number;
  /** Resolved rootfs path (Task 3 `resolveRootfs().path`). */
  rootfs: string;
  // HOST paths:
  workspaceDir: string;
  homeDir: string;
  etcDir: string;
}

/** Exactly one of `command` (parsed by bash -c) or `argv` (exec'd directly). */
export interface ExecRequest {
  command?: string;
  argv?: string[];
  /** Jail-side working directory; default /workspace. */
  cwd?: string;
  /** Merged over BASE_JAIL_ENV inside the jail. */
  env?: Record<string, string>;
  timeoutMs?: number;
  stdin?: string;
  maxOutputBytes?: number;
}

export interface ExecResult {
  exitCode: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  truncated: boolean;
  /** Layer-1 policy refused the request — nothing was spawned. */
  blocked: boolean;
  refusal: string | null;
}

export const EXEC_TIMEOUT_DEFAULT_MS = 120_000;
export const EXEC_TIMEOUT_MAX_MS = 600_000;
export const EXEC_OUTPUT_CAP_BYTES = 1_048_576;
