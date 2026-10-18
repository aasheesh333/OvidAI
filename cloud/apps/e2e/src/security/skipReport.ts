/**
 * P10 Task 8 — loud skip reporting for the permanent security corpus.
 *
 * Review Focus #4 ("the security corpus silently never runs") is the whole
 * point of this module: on a CI box without bwrap / cgroups / loop-mount
 * capability, every skipped corpus group MUST print a visible
 * `SKIPPED: <reason>` line and be counted, and the file-level summary MUST
 * print
 *
 *     security corpus: <N> ran, <M> SKIPPED: <reason>; <reason>; …
 *
 * Task 14's acceptance gate parses that summary and fails the release when
 * `M > 0` on the release box. A suite that registers zero cases is itself
 * reported as a skip — a silent zero-test green is impossible.
 *
 * SELF-DEFENCE: `OVID_SECURITY_STRICT=1` makes `assertSecurityStrict()` throw
 * when `M > 0` (the suite is red without relying on the caller), and
 * `OVID_SECURITY_REPORT=/path.json` persists a machine-readable
 * `{ ran, skipped, reasons, strict, generatedAt }` artifact.
 *
 * `capabilityGate()` probes the host exactly once per suite (callers may
 * inject probes for deterministic unit tests). The check list is pinned by
 * the P10 plan:
 *   - Linux,
 *   - running as root,
 *   - a working bwrap binary (the same trivial jail P2's host gate uses),
 *   - cgroup v2 mounted and writable, with cpu/memory/pids controllers,
 *   - the staging nftables ruleset loaded (optional per group — see
 *     `requireNft`),
 *   - a usable rootfs (staging `OVID_ROOTFS` / `/opt/ovid-rootfs/current`).
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmdirSync, statfsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { parseRootfsManifest } from "@ovid/sandbox";

/** The exact prefix Task 14 greps for. */
export const SECURITY_SUMMARY_PREFIX = "security corpus:";

/** Default staging egress table rendered by P2's render-nft (Task 8 plan). */
export const STAGING_NFT_TABLE = "sandbox_egress_staging";

/** cgroup v2 superblock magic (`CGROUP2_SUPER_MAGIC`). */
const CGROUP2_SUPER_MAGIC = 0x63677270;

/**
 * Files `resolveRootfs` requires. Kept in sync with @ovid/sandbox's
 * rootfs.ts (the constant is private to that module and `cloud/packages/**`
 * is outside this fix's commit lane, so it cannot be imported here). The
 * manifest SCHEMA is validated with the package's own parser below, so only
 * this list can drift.
 */
const ROOTFS_REQUIRED_FILES = [
  "usr/bin/env",
  "usr/local/bin/node",
  "usr/local/bin/pnpm",
  "usr/local/bin/uv",
  "usr/bin/git",
  "usr/bin/python3",
  "usr/local/bin/ovid",
] as const;

export interface CapabilityGate {
  ok: boolean;
  /** Human-readable, one entry per failed capability. */
  reasons: string[];
}

export interface CapabilityGateOptions {
  env?: NodeJS.ProcessEnv;
  platform?: NodeJS.Platform;
  isRoot?: boolean;
  bwrapPath?: string;
  cgroupRoot?: string;
  nftTable?: string;
  rootfsPath?: string;
  /** Default true — the full plan gate includes the staging egress rules. */
  requireNft?: boolean;
  /** Default true — no jail can run without a rootfs. */
  requireRootfs?: boolean;
  /** Injection seams (deterministic unit tests). Return null when capable. */
  probeBwrap?: (path: string) => string | null;
  probeCgroup?: (root: string) => string | null;
  probeNft?: (table: string) => string | null;
  probeRootfs?: (path: string) => string | null;
}

function errText(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/**
 * Trivial jail probe — mirrors @ovid/sandbox's `jailMechanismAvailable` AND
 * the real invocation (`buildBwrapArgs`, launch:"setuid"). The userns flags
 * are load-bearing: a host with bwrap but unprivileged user namespaces
 * disabled passes a plain `--ro-bind` probe and then fails every real jail.
 */
function defaultBwrapProbe(path: string): string | null {
  if (!existsSync(path)) return `bwrap binary missing at ${path}`;
  const res = spawnSync(
    path,
    [
      "--ro-bind",
      "/",
      "/",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--unshare-user",
      "--uid",
      "0",
      "--gid",
      "0",
      "/bin/true",
    ],
    { timeout: 5_000 },
  );
  if (res.error !== undefined) return `bwrap probe failed (${errText(res.error)})`;
  if (res.status !== 0) return `bwrap probe exited ${String(res.status)} (userns/mechanism unavailable)`;
  return null;
}

function defaultCgroupProbe(root: string): string | null {
  try {
    const fsType = statfsSync(root).type;
    if (fsType !== CGROUP2_SUPER_MAGIC) {
      return `${root} is not a cgroup v2 mount (type 0x${fsType.toString(16)})`;
    }
  } catch (err) {
    return `${root} is not readable (${errText(err)})`;
  }

  let controllers: string[];
  try {
    controllers = readFileSync(join(root, "cgroup.controllers"), "utf8").trim().split(/\s+/);
  } catch (err) {
    return `cannot read ${join(root, "cgroup.controllers")} (${errText(err)})`;
  }
  const missing = ["cpu", "memory", "pids"].filter((c) => !controllers.includes(c));
  if (missing.length > 0) return `cgroup controllers missing: ${missing.join(", ")}`;

  // The corpus creates its probe base directly under the root and enables
  // "+cpu +memory +pids" on the base's cgroup.subtree_control. That write
  // only succeeds if the ROOT delegates those controllers — a probe that
  // stops at cgroup.controllers would pass and then fail at manager.init().
  let delegated: string[];
  try {
    delegated = readFileSync(join(root, "cgroup.subtree_control"), "utf8")
      .trim()
      .split(/\s+/)
      .filter(Boolean);
  } catch (err) {
    return `cannot read ${join(root, "cgroup.subtree_control")} (${errText(err)})`;
  }
  const notDelegated = ["cpu", "memory", "pids"].filter((c) => !delegated.includes(c));
  if (notDelegated.length > 0) {
    return `cgroup root ${root} does not delegate ${notDelegated.join(", ")} via cgroup.subtree_control (got '${delegated.join(" ")}')`;
  }

  // Definitive writability probe: create + remove a throwaway cgroup. This
  // proves the corpus can build its own probe base; it never touches the
  // staging/prod worker cgroup paths.
  const probe = join(root, `ovid-probe-sec-gate-${process.pid}`);
  try {
    mkdirSync(probe);
    rmdirSync(probe);
  } catch (err) {
    return `cgroup root ${root} is not writable (${errText(err)})`;
  }
  return null;
}

function defaultNftProbe(table: string): string | null {
  const res = spawnSync("nft", ["list", "table", "inet", table], {
    encoding: "utf8",
    timeout: 5_000,
  });
  if (res.error !== undefined) {
    return `nft unavailable (${errText(res.error)})`;
  }
  if (res.status !== 0) {
    return `nft staging ruleset table inet ${table} not loaded (run cloud/scripts/staging.sh up)`;
  }
  return null;
}

function defaultRootfsProbe(path: string): string | null {
  let raw: string;
  try {
    raw = readFileSync(join(path, "manifest.json"), "utf8");
  } catch (err) {
    return `rootfs unavailable at ${path} (${errText(err)})`;
  }
  // Full schema, parsed by the SAME validator `resolveRootfs` uses — a
  // name-only check would pass a manifest the real setup then rejects.
  try {
    parseRootfsManifest(JSON.parse(raw));
  } catch (err) {
    return `rootfs at ${path} has an invalid manifest.json (${errText(err)})`;
  }
  for (const rel of ROOTFS_REQUIRED_FILES) {
    if (!existsSync(join(path, rel))) {
      return `rootfs at ${path} is missing ${rel}`;
    }
  }
  return null;
}

/**
 * Probe every host capability the corpus needs. Reasons are collected (not
 * short-circuited) so a skip line names every missing piece at once.
 */
export function capabilityGate(opts: CapabilityGateOptions = {}): CapabilityGate {
  const env = opts.env ?? process.env;
  const platform = opts.platform ?? process.platform;
  const isRoot = opts.isRoot ?? process.getuid?.() === 0;
  const bwrapPath = opts.bwrapPath ?? env.OVID_BWRAP_PATH ?? "/usr/bin/bwrap";
  const cgroupRoot = opts.cgroupRoot ?? env.OVID_CGROUP_ROOT ?? "/sys/fs/cgroup";
  const nftTable = opts.nftTable ?? env.OVID_STAGING_NFT_TABLE ?? STAGING_NFT_TABLE;
  const rootfsPath = opts.rootfsPath ?? env.OVID_ROOTFS ?? "/opt/ovid-rootfs/current";
  const requireNft = opts.requireNft ?? true;
  const requireRootfs = opts.requireRootfs ?? true;

  const reasons: string[] = [];
  if (platform !== "linux") reasons.push(`platform is ${platform}, not linux`);
  if (!isRoot) reasons.push("not running as root (bwrap/cgroups need root)");

  const bwrapReason = (opts.probeBwrap ?? defaultBwrapProbe)(bwrapPath);
  if (bwrapReason !== null) reasons.push(bwrapReason);

  const cgroupReason = (opts.probeCgroup ?? defaultCgroupProbe)(cgroupRoot);
  if (cgroupReason !== null) reasons.push(cgroupReason);

  if (requireNft) {
    const nftReason = (opts.probeNft ?? defaultNftProbe)(nftTable);
    if (nftReason !== null) reasons.push(nftReason);
  }

  if (requireRootfs) {
    const rootfsReason = (opts.probeRootfs ?? defaultRootfsProbe)(rootfsPath);
    if (rootfsReason !== null) reasons.push(rootfsReason);
  }

  return { ok: reasons.length === 0, reasons };
}

// ---------------------------------------------------------------------------
// Accumulator + summary (module-level, consumed by Task 14's gate)
// ---------------------------------------------------------------------------

/** Every skipped group, formatted as `<group>: <reason>`. */
export const SKIPPED_SECURITY: string[] = [];

let ranCount = 0;

/** Clears the accumulator — unit tests only. */
export function resetSecurityReport(): void {
  SKIPPED_SECURITY.length = 0;
  ranCount = 0;
}

export function recordSecurityRun(): void {
  ranCount += 1;
}

/**
 * Records + prints one loud skip line. The line deliberately starts with
 * `SKIPPED:` so a human scanning CI output (or Task 14's grep) cannot miss
 * it.
 */
export function recordSecuritySkip(
  group: string,
  reason: string,
  log: (line: string) => void = console.log,
): void {
  const entry = `${group}: ${reason}`;
  SKIPPED_SECURITY.push(entry);
  log(`SKIPPED: ${entry}`);
}

export interface SecurityCounts {
  ran: number;
  skipped: number;
  reasons: string[];
}

export function securityCorpusCounts(): SecurityCounts {
  return {
    ran: ranCount,
    skipped: SKIPPED_SECURITY.length,
    reasons: [...SKIPPED_SECURITY],
  };
}

/**
 * The summary line. A corpus that registered nothing prints an explicit
 * "corpus did not execute" reason instead of a green-looking `0 SKIPPED`.
 */
export function formatSecuritySummary(): string {
  const { ran, skipped, reasons } = securityCorpusCounts();
  if (ran === 0 && skipped === 0) {
    return `${SECURITY_SUMMARY_PREFIX} 0 ran, 0 SKIPPED: corpus did not execute (no cases registered)`;
  }
  const tail =
    skipped === 0 ? "0 SKIPPED" : `${skipped} SKIPPED: ${reasons.join("; ")}`;
  return `${SECURITY_SUMMARY_PREFIX} ${ran} ran, ${tail}`;
}

export function printSecuritySummary(log: (line: string) => void = console.log): void {
  log(formatSecuritySummary());
}

/** `OVID_SECURITY_STRICT=1` (or `true`) makes skips a suite failure. */
export function securityStrictEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const v = env.OVID_SECURITY_STRICT;
  return v === "1" || v?.toLowerCase() === "true";
}

export interface SecurityReport {
  ran: number;
  skipped: number;
  reasons: string[];
  strict: boolean;
  generatedAt: string;
}

/** Machine-readable snapshot of the accumulator (the JSON artifact body). */
export function securityReport(env: NodeJS.ProcessEnv = process.env): SecurityReport {
  const { ran, skipped, reasons } = securityCorpusCounts();
  return {
    ran,
    skipped,
    reasons,
    strict: securityStrictEnabled(env),
    generatedAt: new Date().toISOString(),
  };
}

/**
 * Persists the JSON artifact when `OVID_SECURITY_REPORT` names a path (Task
 * 14 can read this instead of scraping stdout). Returns the path written, or
 * null when the env var is unset. Console output remains the primary signal.
 */
export function writeSecurityReport(
  path: string | undefined = process.env.OVID_SECURITY_REPORT,
  log: (line: string) => void = console.log,
): string | null {
  if (path === undefined || path === "") return null;
  writeFileSync(path, `${JSON.stringify(securityReport(), null, 2)}\n`, "utf8");
  log(`security corpus report: ${path}`);
  return path;
}

/**
 * Self-defending strict mode. `M > 0` throws, which fails the vitest file
 * (the afterAll hook). Without this the corpus relies entirely on Task 14
 * parsing the summary line; with it, `OVID_SECURITY_STRICT=1` in the release
 * environment makes a skipped group a red suite by itself.
 */
export function assertSecurityStrict(env: NodeJS.ProcessEnv = process.env): void {
  if (!securityStrictEnabled(env)) return;
  const { skipped, reasons } = securityCorpusCounts();
  if (skipped > 0) {
    throw new Error(
      `OVID_SECURITY_STRICT=1: ${skipped} security corpus group(s) SKIPPED ` +
        `(the release box must run every group):\n- ${reasons.join("\n- ")}`,
    );
  }
}

/**
 * Wraps a test body with the gate: when the host lacks a capability, the
 * group is counted + printed as SKIPPED and the body never runs. When it is
 * capable, the run is counted first (a mid-test failure still ran).
 */
export function securityCase(
  group: string,
  gate: CapabilityGate,
  body: () => void | Promise<void>,
  log: (line: string) => void = console.log,
): () => Promise<void> {
  return async () => {
    if (!gate.ok) {
      recordSecuritySkip(group, gate.reasons.join("; "), log);
      return;
    }
    recordSecurityRun();
    await body();
  };
}
