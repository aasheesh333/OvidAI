import { fileURLToPath } from "node:url";

/** cgroup v2 resource limits applied to every sandbox. */
export interface SandboxLimits {
  /** cpu.max "<quota period>". */
  cpuMax: string;
  /** memory.max, in bytes. */
  memoryMaxBytes: number;
  /** memory.swap_max, in bytes (0 = no swap). */
  memorySwapMaxBytes: number;
  /** pids.max. */
  pidsMax: number;
}

/** Production defaults; OVID_SANDBOX_{CPU_MAX,MEMORY_MAX_MB,SWAP_MAX_MB,PIDS_MAX} override. */
export const DEFAULT_SANDBOX_LIMITS: SandboxLimits = {
  cpuMax: "100000 100000",
  memoryMaxBytes: 536_870_912, // 512 MiB
  memorySwapMaxBytes: 0, // no swap — OOM-kill instead of thrashing the host
  pidsMax: 64,
};

/**
 * How the sandbox launcher gains the privileges to jail a uid (P2 Task 1
 * DECISION). "setuid" is the working assumption per the controller ruling —
 * MECHANISM.md's DECISION line is still pending, and the env override
 * (OVID_SANDBOX_LAUNCH) always wins over this default.
 */
export type LaunchStrategy = "setuid" | "rootmap";

/** Resolved sandbox configuration (P2 spec §4/§11). */
export interface SandboxConfig {
  workspacesRoot: string;
  rootfsPath: string;
  cgroupRoot: string;
  cgroupBase: string;
  /** First uid of the sandbox block; ≥ 100000, configurable per environment. */
  uidBase: number;
  /** Last uid of the block: uidBase < uidMax ≤ uidBase + 9999 (width fixed at 10 000). */
  uidMax: number;
  maxActiveSandboxes: number;
  acquireTimeoutMs: number;
  workspaceQuotaMb: number;
  proWorkspaceQuotaMb: number;
  storeQuotaMb: number;
  maxWarmGb: number;
  /** Fixed at 2 in v1 — deliberately not env-tunable. */
  minFreeGb: number;
  limits: SandboxLimits;
  sandboxDns: string[];
  bwrapPath: string;
  launcherPath: string;
  launch: LaunchStrategy;
}

const MB = 1024 * 1024;

// Production block (spec §11): 200000–209999. Staging (P10) overrides the
// base via OVID_SANDBOX_UID_BASE=220000 — the range is base-relative, so the
// same validation and code paths cover both (G4).
const DEFAULT_UID_BASE = 200_000;
const UID_BASE_FLOOR = 100_000; // below this is the system/user range — never sandbox uids
const UID_RANGE_WIDTH = 9_999; // block width is fixed at 10 000 uids

function strEnv(raw: NodeJS.ProcessEnv, name: string, fallback: string): string {
  const v = raw[name];
  return v === undefined || v === "" ? fallback : v;
}

function intEnv(
  raw: NodeJS.ProcessEnv,
  name: string,
  fallback: number,
  { min }: { min: number },
): number {
  const v = raw[name];
  if (v === undefined || v === "") return fallback;
  const n = Number(v);
  if (!Number.isInteger(n) || n < min) {
    throw new Error(
      `OVID config: ${name} must be an integer >= ${min}, got ${JSON.stringify(v)}`,
    );
  }
  return n;
}

function parseDns(raw: NodeJS.ProcessEnv): string[] {
  const v = raw.OVID_SANDBOX_DNS;
  if (v === undefined) return ["1.1.1.1", "9.9.9.9"];
  const servers = v.split(",").map((s) => s.trim());
  // Strict: an empty entry (e.g. "1.1.1.1,," or a bare ",") is malformed,
  // not silently dropped — a typo'd resolver list must fail at boot.
  if (servers.length === 0 || servers.some((s) => s.length === 0)) {
    throw new Error(
      `OVID config: OVID_SANDBOX_DNS must be a comma list with at least one resolver, got ${JSON.stringify(v)}`,
    );
  }
  return servers;
}

function parseLaunch(raw: NodeJS.ProcessEnv): LaunchStrategy {
  const v = raw.OVID_SANDBOX_LAUNCH;
  if (v === undefined || v === "") return "setuid"; // Task 1 DECISION pending; env override wins
  if (v !== "setuid" && v !== "rootmap") {
    throw new Error(
      `OVID config: OVID_SANDBOX_LAUNCH must be "setuid" or "rootmap", got ${JSON.stringify(v)}`,
    );
  }
  return v;
}

/**
 * Parse OVID_SANDBOX_UID_BASE/OVID_SANDBOX_UID_MAX into the sandbox uid
 * block. Exported for reuse (renderNftCli renders the egress rules keyed on
 * the SAME block — one validator, no drift; Task 11 M2).
 */
export function parseUidRange(raw: NodeJS.ProcessEnv): { uidBase: number; uidMax: number } {
  const baseRaw = raw.OVID_SANDBOX_UID_BASE;
  let uidBase = DEFAULT_UID_BASE;
  if (baseRaw !== undefined && baseRaw !== "") {
    const n = Number(baseRaw);
    if (!Number.isInteger(n) || n < UID_BASE_FLOOR) {
      throw new Error(
        `OVID config: OVID_SANDBOX_UID_BASE must be an integer >= ${UID_BASE_FLOOR}, got ${JSON.stringify(baseRaw)}`,
      );
    }
    uidBase = n;
  }

  const maxRaw = raw.OVID_SANDBOX_UID_MAX;
  let uidMax = uidBase + UID_RANGE_WIDTH;
  if (maxRaw !== undefined && maxRaw !== "") {
    const n = Number(maxRaw);
    if (!Number.isInteger(n)) {
      throw new Error(
        `OVID config: OVID_SANDBOX_UID_MAX must be an integer, got ${JSON.stringify(maxRaw)}`,
      );
    }
    uidMax = n;
  }
  if (uidMax <= uidBase || uidMax > uidBase + UID_RANGE_WIDTH) {
    throw new Error(
      `OVID config: OVID_SANDBOX_UID_MAX must satisfy uidBase < OVID_SANDBOX_UID_MAX <= uidBase + ${UID_RANGE_WIDTH} (uidBase=${uidBase}), got ${uidMax}`,
    );
  }
  return { uidBase, uidMax };
}

/**
 * Resolve sandbox configuration from the environment. Malformed values throw
 * an Error naming the offending variable — fail fast at boot, never at
 * sandbox-launch time. An empty string counts as unset (except DNS, where an
 * explicitly empty list is rejected).
 */
export function loadSandboxConfig(raw: NodeJS.ProcessEnv = process.env): SandboxConfig {
  const { uidBase, uidMax } = parseUidRange(raw);
  return {
    workspacesRoot: strEnv(raw, "OVID_WORKSPACES_ROOT", "/workspaces/users"),
    rootfsPath: strEnv(raw, "OVID_ROOTFS", "/opt/ovid-rootfs/current"),
    cgroupRoot: strEnv(raw, "OVID_CGROUP_ROOT", "/sys/fs/cgroup"),
    cgroupBase: strEnv(raw, "OVID_CGROUP_BASE", "ovid-sandboxes.slice/ovid-worker.service"),
    uidBase,
    uidMax,
    maxActiveSandboxes: intEnv(raw, "OVID_MAX_ACTIVE_SANDBOXES", 24, { min: 1 }),
    acquireTimeoutMs: intEnv(raw, "OVID_ACQUIRE_TIMEOUT_MS", 60_000, { min: 1 }),
    workspaceQuotaMb: intEnv(raw, "OVID_WORKSPACE_QUOTA_MB", 500, { min: 1 }),
    proWorkspaceQuotaMb: intEnv(raw, "OVID_PRO_WORKSPACE_QUOTA_MB", 2048, { min: 1 }),
    storeQuotaMb: intEnv(raw, "OVID_STORE_QUOTA_MB", 2048, { min: 1 }),
    maxWarmGb: intEnv(raw, "OVID_MAX_WARM_GB", 8, { min: 1 }),
    minFreeGb: 2, // fixed in v1
    limits: {
      cpuMax: strEnv(raw, "OVID_SANDBOX_CPU_MAX", DEFAULT_SANDBOX_LIMITS.cpuMax),
      memoryMaxBytes:
        intEnv(raw, "OVID_SANDBOX_MEMORY_MAX_MB", 512, { min: 1 }) * MB,
      memorySwapMaxBytes:
        intEnv(raw, "OVID_SANDBOX_SWAP_MAX_MB", 0, { min: 0 }) * MB,
      pidsMax: intEnv(raw, "OVID_SANDBOX_PIDS_MAX", 64, { min: 1 }),
    },
    sandboxDns: parseDns(raw),
    bwrapPath: strEnv(raw, "OVID_BWRAP_PATH", "/usr/bin/bwrap"),
    launcherPath: strEnv(
      raw,
      "OVID_SANDBOX_LAUNCHER",
      // <package root>/bin/sandbox-enter.sh — one level up from this module,
      // which holds for both src/config.ts and dist/config.js.
      fileURLToPath(new URL("../bin/sandbox-enter.sh", import.meta.url)),
    ),
    launch: parseLaunch(raw),
  };
}
