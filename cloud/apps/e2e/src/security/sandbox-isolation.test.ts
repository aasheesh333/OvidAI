/**
 * P10 Task 8 — permanent sandbox isolation corpus (security suite I).
 *
 * This file is the promotion of P2's live-proven isolation properties into
 * the permanent e2e suite. It runs the REAL sandbox chain (real bwrap, real
 * cgroups, real rootfs) with a throwaway probe cgroup base and a throwaway
 * workspace root — never the prod/staging worker paths.
 *
 * RUNNING IT
 * ----------
 * On the release/staging box:
 *
 *     cloud/scripts/staging.sh up          # loads the staging nft ruleset
 *     cd cloud && OVID_SANDBOX_HOST_TESTS=1 OVID_ROOTFS=/opt/ovid-rootfs/current \
 *       pnpm --filter @ovid/e2e exec vitest run src/security/sandbox-isolation.test.ts
 *
 * `OVID_ROOTFS` must point at a CURRENT extracted rootfs (the r2 extract on
 * the sandbox host — DEPLOY.md §11). The staging uid block is
 * 220000–229999 and the egress table is `sandbox_egress_staging`; both are
 * what `staging.sh up` provisions.
 *
 * Set `OVID_SECURITY_STRICT=1` to make any skipped group fail this file, and
 * `OVID_SECURITY_REPORT=/path.json` to persist the machine-readable summary.
 *
 * COVERAGE DEVIATION — `./gradlew` (Task 8 review M5)
 * --------------------------------------------------
 * `./gradlew` (and the bare `assembleDebug`/`assembleRelease` task words) are
 * asserted at LAYER 1 only. Layer 2 is a PATH shim roster, and `./gradlew`
 * is a project-local PATH, not a PATH lookup, so no shim can intercept it.
 * Tool calls are safe because `checkCommandPolicy` refuses `./gradlew` before
 * `sandbox.exec` (`apps/worker/src/tools/shellTool.ts`). The interactive PTY
 * path bypasses layer 1 BY DESIGN and therefore has no layer-2 defense for a
 * project-local `./gradlew`; that path is not exercised here. This is a
 * documented deviation from the review matrix's "every §7 command × every
 * invocation form", not an untested escape that the corpus claims to cover.
 *
 * SKIP DISCIPLINE (Review Focus #4)
 * ---------------------------------
 * When the host lacks bwrap, cgroup v2, the staging nft ruleset, rootfs or
 * root, every gated group prints a loud `SKIPPED: <reason>` line and is
 * counted; the file-level summary is
 * `security corpus: N ran, M SKIPPED: <reasons>`. Task 14's acceptance gate
 * fails the release if M > 0 on the release box. The layer-1 denylist half
 * runs on any host and is never skipped.
 *
 * SAFETY
 * ------
 * The egress group verifies the uid-keyed nft rules (and proves the filter
 * works against an unreachable address) BEFORE touching loopback or the
 * box's own public IP. The memory/pids hogs are bounded by the production
 * caps (512 MiB / 64 pids) and run inside a throwaway env cgroup.
 */

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmodSync,
  chownSync,
  existsSync,
  lchownSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  rmdirSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import {
  createCgroupManager,
  createNoopQuotaBackend,
  createSandboxManager,
  createSetuidLauncher,
  DEFAULT_SANDBOX_LIMITS,
  loadSandboxConfig,
  REFUSAL_MESSAGE,
  renderEtcBundle,
  resolveRootfs,
  type CgroupManager,
  type SandboxConfig,
  type SandboxHandle,
  type SandboxManager,
} from "@ovid/sandbox";

import {
  ALLOWED_DENYLIST_CORPUS,
  classifyCommand,
  EXECUTION_DENYLIST_CORPUS,
  LAYER1_DENYLIST_CORPUS,
  LAYER2_DENYLIST_CORPUS,
} from "./denylist-corpus.js";
import {
  assertSecurityStrict,
  capabilityGate,
  printSecuritySummary,
  recordSecurityRun,
  securityCase,
  writeSecurityReport,
  type CapabilityGate,
} from "./skipReport.js";

// ---------------------------------------------------------------------------
// Host / staging constants
// ---------------------------------------------------------------------------

const CG_ROOT = process.env.OVID_CGROUP_ROOT ?? "/sys/fs/cgroup";
/** Throwaway probe base — never the prod/staging worker cgroup path. */
const BASE = `ovid-probe-sec-${process.pid}`;

const USER = "security-corpus-user";
/** P2 staging rule: hash-allocate inside 220000..229999. */
const UID_BASE = 220000;
const UID_MAX = 229999;
const UID =
  UID_BASE + (createHash("sha256").update(USER).digest().readUInt32BE(0) % (UID_MAX - UID_BASE + 1));

const BWRAP_PATH = process.env.OVID_BWRAP_PATH ?? "/usr/bin/bwrap";
const ROOTFS_PATH = process.env.OVID_ROOTFS ?? "/opt/ovid-rootfs/current";
const STAGING_NFT_TABLE = process.env.OVID_STAGING_NFT_TABLE ?? "sandbox_egress_staging";
const OWN_PUBLIC_IP = process.env.OVID_PUBLIC_IP ?? "148.113.44.36";
const LIVE_GATEWAY_PORT = process.env.OVID_PUBLIC_GATEWAY_PORT ?? "8082";

const HOST_OPT_IN: CapabilityGate = {
  ok: process.env.OVID_SANDBOX_HOST_TESTS === "1",
  reasons: process.env.OVID_SANDBOX_HOST_TESTS === "1"
    ? []
    : ["host proof not run: set OVID_SANDBOX_HOST_TESTS=1 explicitly"],
};

/** Non-egress groups do not need the nft staging table. No capability probe
 * runs before the explicit host opt-in. */
const baseGate: CapabilityGate = HOST_OPT_IN.ok
  ? capabilityGate({
      bwrapPath: BWRAP_PATH,
      cgroupRoot: CG_ROOT,
      rootfsPath: ROOTFS_PATH,
      requireNft: false,
    })
  : HOST_OPT_IN;

/** The egress group additionally requires the staging nft ruleset. */
const egressGate: CapabilityGate = HOST_OPT_IN.ok
  ? capabilityGate({
      bwrapPath: BWRAP_PATH,
      cgroupRoot: CG_ROOT,
      rootfsPath: ROOTFS_PATH,
      nftTable: STAGING_NFT_TABLE,
      requireNft: true,
    })
  : HOST_OPT_IN;

function title(label: string, gate: CapabilityGate): string {
  return gate.ok ? label : `${label} [SKIPPED]`;
}

// ---------------------------------------------------------------------------
// cgroup / proc helpers (same discipline as P2's host suites)
// ---------------------------------------------------------------------------

function readProcSelfCgroup(): string {
  const line = readFileSync("/proc/self/cgroup", "utf8")
    .trim()
    .split("\n")
    .find((l) => l.startsWith("0::"));
  if (!line) throw new Error("not a cgroups v2 host: no 0:: line in /proc/self/cgroup");
  return line.slice(3);
}

const ORIGINAL_CGROUP = readProcSelfCgroup();

function moveSelfTo(cgroupPath: string): void {
  writeFileSync(join(CG_ROOT, cgroupPath, "cgroup.procs"), String(process.pid));
}

function readProcs(cgroupPath: string): number[] {
  try {
    return readFileSync(join(cgroupPath, "cgroup.procs"), "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(Number);
  } catch {
    return [];
  }
}

/** Depth-first kill+remove of a probe cgroup subtree (cgroupfs: rmdir only). */
async function removeCgroupTree(path: string, selfPid: number): Promise<void> {
  if (!existsSync(path)) return;
  for (const e of readdirSync(path, { withFileTypes: true })) {
    if (e.isDirectory()) await removeCgroupTree(join(path, e.name), selfPid);
  }
  if (!readProcs(path).includes(selfPid)) {
    try {
      writeFileSync(join(path, "cgroup.kill"), "1");
    } catch {
      /* not a cgroup / already gone */
    }
  }
  for (let i = 0; i < 100; i++) {
    const pids = readProcs(path);
    if (pids.length === 0) break;
    for (const p of pids) {
      if (p === selfPid) continue;
      try {
        process.kill(p, "SIGKILL");
      } catch {
        /* already gone */
      }
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 50));
  }
  try {
    rmdirSync(path);
  } catch {
    /* already gone */
  }
}

/** Host processes whose REAL uid is `uid` (scan /proc/<pid>/status). */
function scanForUid(uid: number): number {
  let n = 0;
  for (const entry of readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const status = readFileSync(join("/proc", entry, "status"), "utf8");
      const m = status.match(/^Uid:\s+(\d+)/m);
      if (m !== null && Number(m[1]) === uid) n++;
    } catch {
      /* process gone between readdir and read */
    }
  }
  return n;
}

async function untilZero(fn: () => number, ms: number): Promise<number> {
  const deadline = Date.now() + ms;
  let v = fn();
  while (v !== 0 && Date.now() < deadline) {
    await new Promise<void>((resolve) => setTimeout(resolve, 100));
    v = fn();
  }
  return v;
}

async function untilAtLeast(fn: () => Promise<number>, target: number, ms: number): Promise<number> {
  const deadline = Date.now() + ms;
  let v = await fn();
  while (v < target && Date.now() < deadline) {
    await new Promise<void>((resolve) => setTimeout(resolve, 50));
    v = await fn();
  }
  return v;
}

/**
 * Total `pids.events` max hits in an env cgroup AND its live leaves.
 * Execs run in a per-command leaf (`exec-N-…`), and the kernel charges the
 * hit to THAT cgroup — the env parent stays at `max 0`. Reading only the
 * parent made this assertion unable to observe the cap.
 */
function sumPidsMaxEvents(dir: string): number {
  let total = 0;
  const visit = (path: string, depth: number): void => {
    try {
      const text = readFileSync(join(path, "pids.events"), "utf8");
      const m = /^max (\d+)$/m.exec(text);
      if (m !== null) total += Number(m[1]);
    } catch {
      return;
    }
    if (depth >= 4) return;
    let entries;
    try {
      entries = readdirSync(path, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.isDirectory()) visit(join(path, entry.name), depth + 1);
    }
  };
  visit(dir, 0);
  return total;
}

function memAvailableKb(): number {
  const m = /^MemAvailable:\s+(\d+) kB$/m.exec(readFileSync("/proc/meminfo", "utf8"));
  if (m === null) throw new Error("MemAvailable missing from /proc/meminfo");
  return Number(m[1]);
}

/** If the live stack is present on this host, it must still be Up. */
function assertLiveContainersUp(): void {
  const res = spawnSync(
    "docker",
    ["ps", "--filter", "name=ovid-gateway-", "--format", "{{.Names}} {{.Status}}"],
    { encoding: "utf8", timeout: 10_000 },
  );
  if (res.error !== undefined || res.status !== 0) return; // no docker on this host
  const lines = res.stdout.trim().split("\n").filter(Boolean);
  for (const line of lines) {
    expect(line, `live container affected: ${line}`).toMatch(/\bUp\b/);
  }
}

// ---------------------------------------------------------------------------
// nft helpers (egress group)
// ---------------------------------------------------------------------------

function nftTableText(): string {
  const res = spawnSync("nft", ["list", "table", "inet", STAGING_NFT_TABLE], {
    encoding: "utf8",
    timeout: 10_000,
  });
  if (res.status !== 0) {
    throw new Error(
      `nft list table inet ${STAGING_NFT_TABLE} failed: ${res.stderr.trim() || res.stdout.trim()}`,
    );
  }
  return res.stdout;
}

function ruleCounter(text: string, predicate: (line: string) => boolean): number {
  for (const line of text.split("\n")) {
    if (!predicate(line)) continue;
    const m = /counter packets (\d+)/.exec(line);
    if (m !== null) return Number(m[1]);
  }
  throw new Error(`nft counter line not found in table inet ${STAGING_NFT_TABLE}:\n${text}`);
}

function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Matcher for one `nft list table` rule line. `renderNftRuleset` emits an
 * anonymous `counter drop`, but `nft list` EXPANDS it to
 * `counter packets N bytes M drop` (reproduced with nft 1.0.9 in a
 * disposable netns). Asserting the pre-load text is a false negative that
 * throws before any packet is sent (Task 8 review H1).
 */
function rulePattern(prefix: string): RegExp {
  return new RegExp(`${escapeRegExp(prefix)} counter packets \\d+ bytes \\d+ drop`);
}

async function curlInJail(handle: SandboxHandle, url: string) {
  return handle.exec({
    command: `curl -m 5 -s -o /dev/null -w '%{http_code}' ${url}`,
    timeoutMs: 15_000,
  });
}

function shSingle(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

// Writes an outcome even when the connection is refused/times out, so a
// postinstall that never ran cannot be mistaken for a successful denial.
const RAW_SOCKET_PY = [
  "import json, socket, sys",
  "address, port, output = sys.argv[1], int(sys.argv[2]), sys.argv[3]",
  "try:",
  "    s = socket.create_connection((address, port), timeout=5)",
  "    s.close()",
  "    outcome = {'rc': 0, 'error': 'connected'}",
  "except socket.timeout:",
  "    outcome = {'rc': 28, 'error': 'ETIMEDOUT'}",
  "except OSError as e:",
  "    outcome = {'rc': 1, 'error': f'{type(e).__name__}: {e}'}",
  "with open(output, 'w') as f:",
  "    json.dump(outcome, f)",
].join("\n");

async function rawSocketInJail(
  handle: SandboxHandle,
  address: string,
  port: number,
  outputName: string,
): Promise<{ rc: number; error: string }> {
  const result = await handle.exec({
    command: `python3 /workspace/ovid-raw-probe.py ${shSingle(address)} ${port} ${shSingle(`/workspace/${outputName}`)}`,
    timeoutMs: 20_000,
  });
  expect(result.exitCode, `raw socket probe failed: ${result.stderr}`).toBe(0);
  return JSON.parse(readFileSync(join(handle.workspaceDir, outputName), "utf8")) as {
    rc: number;
    error: string;
  };
}

// ---------------------------------------------------------------------------
// Portable half: layer-1 denylist (never skipped, no host capability needed)
// ---------------------------------------------------------------------------

describe("security — command-policy denylist (layer 1, portable)", () => {
  it("refuses every §7 blocked command in every invocation form (real layer-1 verdict)", () => {
    recordSecurityRun();
    expect(LAYER1_DENYLIST_CORPUS.length).toBeGreaterThanOrEqual(150);
    for (const c of LAYER1_DENYLIST_CORPUS) {
      const verdict = classifyCommand(c.command);
      expect(verdict.allowed, `${c.id}: ${JSON.stringify(c.command)} must be blocked`).toBe(false);
      // Produced by the real `checkCommandPolicy`, not synthesized by the
      // adapter (review M3).
      expect(verdict.matched, `${c.id}: the real interceptor must name a match`).toBeTruthy();
      expect(verdict.segment, `${c.id}: the offending segment must be reported`).toBeTruthy();
    }

    // The §7 copy is pinned ONCE here as a literal. The in-jail execution
    // group (7) proves the exec path actually emits it. Asserting
    // `verdict.refusal === REFUSAL_MESSAGE` per case was tautological because
    // the adapter fabricated the field.
    expect(REFUSAL_MESSAGE).toBe(
      "Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead.",
    );
  });

  it("the egress rule matcher accepts nft's expanded anonymous-counter form", () => {
    recordSecurityRun();
    const prefix = "meta skuid 220000-229999 ip daddr @blocked_v4";
    // Exactly what `nft list table` prints after loading the renderer output
    // (nft 1.0.9, disposable netns):
    expect(`${prefix} counter packets 0 bytes 0 drop`).toMatch(rulePattern(prefix));
    expect(`${prefix} counter packets 42 bytes 3360 drop`).toMatch(rulePattern(prefix));
    // The pre-load rendering is NOT the listed form; asserting it is the H1
    // false negative.
    expect(`${prefix} counter drop`).not.toMatch(rulePattern(prefix));
    // A renamed/removed rule must not match.
    expect(
      "meta skuid 220000-229999 ip daddr 10.0.0.0/8 counter packets 0 bytes 0 drop",
    ).not.toMatch(rulePattern(prefix));
  });

  it("documents the layer-1 boundary (base64) instead of pretending it is static", () => {
    recordSecurityRun();
    expect(LAYER2_DENYLIST_CORPUS.length).toBeGreaterThan(0);
    for (const c of LAYER2_DENYLIST_CORPUS) {
      // Base64 payloads are NOT statically decodable; the in-jail PATH shims
      // are the defense (proven by the gated execution group). A regression
      // that starts blocking them at layer 1 would be a false-positive
      // change. (Variable indirection moved to the layer-1 corpus with the
      // 2026-10-18 evasion fix: `$`-headed segments are now refused.)
      expect(
        classifyCommand(c.command).allowed,
        `${c.id}: ${JSON.stringify(c.command)} is a documented layer-2 boundary`,
      ).toBe(true);
    }
  });

  it("does not block the allowed set", () => {
    recordSecurityRun();
    for (const command of ALLOWED_DENYLIST_CORPUS) {
      expect(classifyCommand(command).allowed, `${JSON.stringify(command)} must not be blocked`).toBe(
        true,
      );
    }
  });
});

// ---------------------------------------------------------------------------
// Host-gated half: the isolation corpus
// ---------------------------------------------------------------------------

let manager: SandboxManager | undefined;
let handle: SandboxHandle | undefined;
let rawMgr: CgroupManager | undefined;
let wsRoot = "";
let summaryPrinted = false;

function emitSummaryOnce(): void {
  if (summaryPrinted) return;
  summaryPrinted = true;
  printSecuritySummary();
  writeSecurityReport();
}

function ctx(): { handle: SandboxHandle; rawMgr: CgroupManager } {
  if (handle === undefined || rawMgr === undefined) {
    throw new Error("security corpus setup missing despite a passing capability gate");
  }
  return { handle, rawMgr };
}

afterAll(() => {
  // Backstop: even if the gated afterAll below never runs (import/setup
  // failure), the summary is still visible. Strict mode is enforced here so
  // `OVID_SECURITY_STRICT=1` makes a skipped group a red suite even when the
  // caller does not parse the summary line.
  emitSummaryOnce();
  assertSecurityStrict();
});

describe("security — sandbox isolation corpus (host-gated)", () => {
  beforeAll(async () => {
    if (!baseGate.ok) return;
    wsRoot = mkdtempSync(join(tmpdir(), "ovid-sec-ws-"));
    // mkdtemp creates 0700 root-owned. The sandbox uid must TRAVERSE this
    // root to reach its own `{uid}/workspace`, exactly as it traverses the
    // production `/workspaces` (0755 root-owned); without this every bwrap
    // bind under it fails with "Permission denied".
    chmodSync(wsRoot, 0o755);
    const cfg: SandboxConfig = {
      ...loadSandboxConfig({
        OVID_SANDBOX_UID_BASE: String(UID_BASE),
        OVID_SANDBOX_UID_MAX: String(UID_MAX),
        OVID_ROOTFS: ROOTFS_PATH,
        OVID_BWRAP_PATH: BWRAP_PATH,
        OVID_CGROUP_ROOT: CG_ROOT,
      }),
      workspacesRoot: wsRoot,
      cgroupRoot: CG_ROOT,
      cgroupBase: BASE,
      rootfsPath: ROOTFS_PATH,
      launch: "setuid",
      limits: { ...DEFAULT_SANDBOX_LIMITS },
    };

    rawMgr = createCgroupManager({ cgroupRoot: CG_ROOT, cgroupBase: BASE });
    await rawMgr.init(); // leaf-first bootstrap (no-internal-process rule)
    // init() parked this process in the probe base's worker leaf; move it
    // back out so the vitest tree never lives in the throwaway cgroup.
    moveSelfTo(ORIGINAL_CGROUP);

    const rootfs = await resolveRootfs(ROOTFS_PATH);
    manager = createSandboxManager({
      config: cfg,
      // The staging allocator is hash-based inside the configured block;
      // this fixed stub pins the same uid for the whole corpus.
      allocateUid: async () => UID,
      cgroups: rawMgr,
      quota: createNoopQuotaBackend(),
      launcher: createSetuidLauncher(cfg),
      rootfs,
    });
    handle = await manager.attach(USER);
  }, 120_000);

  afterAll(async () => {
    const problems: string[] = [];
    if (baseGate.ok) {
      try {
        await manager?.close();
      } catch (e) {
        problems.push(`manager.close(): ${String(e)}`);
      }
      try {
        moveSelfTo(ORIGINAL_CGROUP);
      } catch (e) {
        problems.push(`restore placement: ${String(e)}`);
      }
      try {
        await removeCgroupTree(join(CG_ROOT, BASE), process.pid);
      } catch (e) {
        problems.push(`cleanup ${BASE}: ${String(e)}`);
      }
      // Remove ONLY this process's own cgroups: the probe base and the
      // capability gate's transient probe. A broad `ovid-probe-sec-*` sweep
      // would kill a concurrent run of this same suite (review L1).
      for (const own of [BASE, `ovid-probe-sec-gate-${process.pid}`]) {
        try {
          await removeCgroupTree(join(CG_ROOT, own), process.pid);
        } catch (e) {
          problems.push(`cleanup ${own}: ${String(e)}`);
        }
      }
      if (wsRoot !== "") {
        try {
          rmSync(wsRoot, { recursive: true, force: true });
        } catch (e) {
          problems.push(`rm ${wsRoot}: ${String(e)}`);
        }
      }
      try {
        const leftover = await untilZero(() => scanForUid(UID), 5_000);
        if (leftover !== 0) problems.push(`leftover uid-${UID} processes: ${leftover}`);
      } catch (e) {
        problems.push(`uid scan: ${String(e)}`);
      }
    }
    emitSummaryOnce();
    if (problems.length > 0) {
      throw new Error(`security corpus cleanup failed:\n- ${problems.join("\n- ")}`);
    }
  }, 120_000);

  it(
    title(
      "(1) path confinement — host /etc, /root/.ssh and the prod workspaces tree are unreachable; RO surfaces reject writes; /workspace is RW",
      baseGate,
    ),
    securityCase("path confinement", baseGate, async () => {
      const { handle: h } = ctx();

      // /etc/shadow: the jail's own rootfs copy may exist (mode 0640), so a
      // nonzero `cat` cannot distinguish ENOENT from EACCES. Compare the
      // (device,inode) pair with the HOST file — a host bind matches exactly
      // (review M1) — then prove no host content leaks.
      const hostShadow = readFileSync("/etc/shadow", "utf8");
      const hostShadowStat = statSync("/etc/shadow");
      const shadow = await h.exec({ command: "cat /etc/shadow", timeoutMs: 20_000 });
      expect(
        shadow.exitCode,
        `jail must not read host /etc/shadow (stdout=${JSON.stringify(shadow.stdout.slice(0, 120))})`,
      ).not.toBe(0);
      expect(shadow.stdout).not.toContain(hostShadow.split("\n")[0]);
      expect(shadow.stdout).not.toMatch(/^[^:\n]+:[^:\n]*:[0-9]+:[0-9]+:/m);
      const shadowStat = await h.exec({
        command: "stat -Lc '%d %i' /etc/shadow",
        timeoutMs: 20_000,
      });
      if (shadowStat.exitCode === 0) {
        expect(
          shadowStat.stdout.trim(),
          "jail /etc/shadow is the HOST file (same device+inode) — host /etc is bind-mounted",
        ).not.toBe(`${hostShadowStat.dev} ${hostShadowStat.ino}`);
      } else {
        expect(shadowStat.stderr, "an absent /etc/shadow must be ENOENT, not EACCES").toMatch(
          /No such file/i,
        );
      }

      // /root/.ssh: the sandbox home is bound at /root, so the host's 0700
      // /root must be ABSENT (ENOENT) — never present-but-EACCES. Compare
      // /root itself too, which catches a host bind even without .ssh.
      const hostRootStat = statSync("/root");
      const jailRootStat = await h.exec({ command: "stat -Lc '%d %i' /root", timeoutMs: 20_000 });
      expect(jailRootStat.exitCode, jailRootStat.stderr).toBe(0);
      expect(
        jailRootStat.stdout.trim(),
        "jail /root is the HOST /root (same device+inode)",
      ).not.toBe(`${hostRootStat.dev} ${hostRootStat.ino}`);
      const ssh = await h.exec({
        command: "stat -Lc '%d %i' /root/.ssh/authorized_keys",
        timeoutMs: 20_000,
      });
      expect(ssh.exitCode, "host /root/.ssh must not be reachable").not.toBe(0);
      expect(
        ssh.stderr,
        "ENOENT expected; EACCES would mean the host /root is mounted but unreadable",
      ).toMatch(/No such file/i);
      const sshCat = await h.exec({
        command: "cat /root/.ssh/authorized_keys",
        timeoutMs: 20_000,
      });
      expect(sshCat.exitCode, "host /root/.ssh must not be readable").not.toBe(0);
      expect(sshCat.stdout).toBe("");

      const prodWs = await h.exec({ command: "ls /workspaces/users", timeoutMs: 20_000 });
      expect(prodWs.exitCode, "the prod workspaces root must not be mounted").not.toBe(0);
      expect(prodWs.stderr).toMatch(/No such file/i);

      // `..` traversal: the jail must not climb out of /workspace. From
      // /workspace, `..` lands on the jail's own rootfs root, never the host
      // (review M2). P2's PATH_ESCAPE_CORPUS covers the tool-side meaning;
      // these are the jail-side forms.
      const hostPasswd = readFileSync("/etc/passwd", "utf8");
      const privatePasswd = renderEtcBundle({ dns: ["1.1.1.1"] }).passwd;
      const hostAuthorized = (() => {
        try {
          return readFileSync("/root/.ssh/authorized_keys", "utf8");
        } catch {
          return "";
        }
      })();
      const traversal = [
        "cd /workspace && cat ../../etc/shadow",
        "cd /workspace && cat ../../../etc/shadow",
        "cat /workspace/../../etc/shadow",
        "cat /workspace/../root/.ssh/authorized_keys",
        "cat /workspace/../../root/.ssh/authorized_keys",
      ];
      for (const command of traversal) {
        const res = await h.exec({ command, timeoutMs: 20_000 });
        expect(res.stdout, `${command} leaked host /etc/shadow`).not.toContain(
          hostShadow.split("\n")[0],
        );
        if (hostAuthorized !== "") {
          expect(res.stdout, `${command} leaked host /root/.ssh`).not.toContain(
            hostAuthorized.split("\n")[0],
          );
        }
      }
      const travPasswd = await h.exec({
        command: "cd /workspace && cat ../../etc/passwd",
        timeoutMs: 20_000,
      });
      if (travPasswd.exitCode === 0) {
        expect(
          travPasswd.stdout,
          "traversal must land on the jail's private /etc/passwd",
        ).toBe(privatePasswd);
      } else {
        expect(travPasswd.stderr).toMatch(/No such file|Permission denied/i);
      }
      expect(travPasswd.stdout, "traversal leaked the HOST /etc/passwd").not.toBe(hostPasswd);

      const ro = await h.exec({ command: "touch /usr/x", timeoutMs: 20_000 });
      expect(ro.exitCode, "the rootfs bind is read-only").not.toBe(0);
      expect(ro.stderr).toMatch(/read-only|Read-only/i);

      // /proc/1 is the jail's OWN PID 1, not the host's.
      const hostCmdline = readFileSync("/proc/1/cmdline", "utf8");
      const hostEnviron = readFileSync("/proc/1/environ", "utf8");
      const hostNsIno = statSync("/proc/1/ns/pid").ino;
      const p1 = await h.exec({ command: "cat /proc/1/cmdline", timeoutMs: 20_000 });
      expect(p1.exitCode, p1.stderr).toBe(0);
      expect(p1.stdout).not.toBe(hostCmdline);
      const p1env = await h.exec({ command: "cat /proc/1/environ", timeoutMs: 20_000 });
      if (p1env.exitCode === 0) expect(p1env.stdout).not.toBe(hostEnviron);
      const ns = await h.exec({ command: "stat -Lc %i /proc/1/ns/pid", timeoutMs: 20_000 });
      expect(ns.exitCode, ns.stderr).toBe(0);
      expect(Number(ns.stdout.trim())).not.toBe(hostNsIno);

      // The workspace RW bind works and the host file belongs to the uid.
      const rw = await h.exec({
        command: "echo security-rw > /workspace/rw.txt && cat /workspace/rw.txt",
        timeoutMs: 20_000,
      });
      expect(rw.exitCode, rw.stderr).toBe(0);
      expect(rw.stdout.trim()).toBe("security-rw");
      expect(statSync(join(h.workspaceDir, "rw.txt")).uid).toBe(UID);
    }),
    240_000,
  );

  it(
    title(
      "(2) symlink handling — host /etc and /root are not reachable through pre-planted links; hardlinks across the RO bind are refused",
      baseGate,
    ),
    securityCase("symlink handling", baseGate, async () => {
      const { handle: h } = ctx();
      const evil = join(h.workspaceDir, "evil");
      const rootlink = join(h.workspaceDir, "rootlink");
      symlinkSync("/etc/passwd", evil);
      lchownSync(evil, UID, UID);
      symlinkSync("/root", rootlink);
      lchownSync(rootlink, UID, UID);

      // A sentinel in the SANDBOX home distinguishes the jail's /root from
      // the host's /root (bwrap binds the per-sandbox home at /root).
      const sentinel = join(h.homeDir, ".sandbox-home-sentinel");
      writeFileSync(sentinel, "jail-home\n", { mode: 0o644 });
      chownSync(sentinel, UID, UID);

      const hostPasswd = readFileSync("/etc/passwd", "utf8");
      const privatePasswd = renderEtcBundle({ dns: ["1.1.1.1"] }).passwd;
      const readEvil = await h.exec({ command: "cat /workspace/evil", timeoutMs: 20_000 });
      expect(readEvil.exitCode, readEvil.stderr).toBe(0);
      expect(readEvil.stdout, "evil must resolve to the jail's private /etc/passwd").toBe(
        privatePasswd,
      );
      expect(readEvil.stdout).not.toBe(hostPasswd);

      // The plan's literal ENOENT/EPERM expectation assumed /root is not
      // mounted; P2 binds the per-sandbox home at /root, so the correct
      // property is "resolves to the jail's own /root, never the host's".
      const lsRoot = await h.exec({ command: "ls -a /workspace/rootlink/", timeoutMs: 20_000 });
      if (lsRoot.exitCode === 0) {
        expect(lsRoot.stdout).toContain(".sandbox-home-sentinel");
        expect(lsRoot.stdout, "host /root content leaked").not.toContain("OvidAI");
        expect(lsRoot.stdout, "host /root content leaked").not.toContain(".claude");
      } else {
        expect(lsRoot.stderr).toMatch(/No such file|Permission denied/i);
      }

      const hard = await h.exec({
        // The rootfs ships node at /usr/local/bin/node (rootfs manifest);
        // the plan's /usr/bin/node does not exist in this tree.
        command: "ln /usr/local/bin/node /workspace/hl",
        timeoutMs: 20_000,
      });
      expect(hard.exitCode, "hardlink out of the RO bind must fail").not.toBe(0);
      expect(hard.stderr).toMatch(
        /Operation not permitted|Invalid cross-device link|Permission denied/i,
      );
      // The documented P2 backstop for same-filesystem attempts.
      expect(readFileSync("/proc/sys/fs/protected_hardlinks", "utf8").trim()).toBe("1");
    }),
    120_000,
  );

  it(
    title(
      "(3) uid map — inner root maps to the staging uid; files written in-jail are host-owned by 22xxxx, never 0",
      baseGate,
    ),
    securityCase("uid map", baseGate, async () => {
      const { handle: h } = ctx();
      expect(UID).toBeGreaterThanOrEqual(UID_BASE);
      expect(UID).toBeLessThanOrEqual(UID_MAX);

      const idu = await h.exec({ command: "id -u", timeoutMs: 20_000 });
      expect(idu.exitCode, idu.stderr).toBe(0);
      expect(idu.stdout.trim()).toBe("0"); // mapped root INSIDE only

      const uidMap = await h.exec({ command: "cat /proc/self/uid_map", timeoutMs: 20_000 });
      expect(uidMap.exitCode, uidMap.stderr).toBe(0);
      // /proc/self/uid_map pads its columns; compare the FIELDS.
      expect(uidMap.stdout.trim().split(/\s+/)).toEqual(["0", String(UID), "1"]);

      const write = await h.exec({
        command: "echo uid-map > /workspace/uid-owned.txt",
        timeoutMs: 20_000,
      });
      expect(write.exitCode, write.stderr).toBe(0);
      const st = statSync(join(h.workspaceDir, "uid-owned.txt"));
      expect(st.uid, "host ownership must be the staging uid").toBe(UID);
      expect(st.uid, "host ownership must never be root").not.toBe(0);

      // In-jail view is the mapped root (0); the host view above is the
      // security-relevant one.
      const inJail = await h.exec({
        command: "stat -c %u /workspace/uid-owned.txt",
        timeoutMs: 20_000,
      });
      expect(inJail.exitCode, inJail.stderr).toBe(0);
      expect(inJail.stdout.trim()).toBe("0");
    }),
    60_000,
  );

  it(
    title(
      "(4) egress — the staging nft rules block metadata/private/loopback/own-IP (counters prove it) while allowed egress works",
      egressGate,
    ),
    securityCase("egress rules", egressGate, async () => {
      const { handle: h } = ctx();
      const uidRange = `${UID_BASE}-${UID_MAX}`;
      const blockedPredicate = (line: string): boolean =>
        line.includes(`meta skuid ${uidRange}`) && line.includes("@blocked_v4");
      const ownPredicate = (line: string): boolean =>
        line.includes(`meta skuid ${uidRange}`) &&
        line.includes(`ip daddr ${OWN_PUBLIC_IP}`) &&
        !line.includes("@blocked_v4");
      const blockedV6Predicate = (line: string): boolean =>
        line.includes(`meta skuid ${uidRange}`) && line.includes("@blocked_v6");

      // Assert the uid-keyed rules EXIST before sending any packet — a
      // missing rule must fail here, not silently probe a live service.
      // `nft list` expands the renderer's anonymous `counter drop` to
      // `counter packets N bytes M drop`, so match the LISTED form (H1).
      const initial = nftTableText();
      expect(initial).toMatch(rulePattern(`meta skuid ${uidRange} ip daddr @blocked_v4`));
      expect(initial).toMatch(rulePattern(`meta skuid ${uidRange} ip6 daddr @blocked_v6`));
      expect(initial).toMatch(rulePattern(`meta skuid ${uidRange} ip daddr ${OWN_PUBLIC_IP}`));
      const blockedStart = ruleCounter(initial, blockedPredicate);
      const blockedV6Start = ruleCounter(initial, blockedV6Predicate);
      const ownStart = ruleCounter(initial, ownPredicate);

      // Safety probe first: an unreachable address proves the filter fires
      // before we touch loopback (staging redis/LiteLLM) or the live box IP.
      const probe = await curlInJail(h, "http://10.255.255.1/");
      expect([28, 7], `10.255.255.1 must be filtered (rc=${probe.exitCode})`).toContain(
        probe.exitCode,
      );
      expect(ruleCounter(nftTableText(), blockedPredicate)).toBeGreaterThan(blockedStart);

      const blockedTargets = [
        "http://169.254.169.254/latest/meta-data/",
        "http://192.168.1.1/",
        "http://172.16.5.4/",
        // CGNAT (100.64.0.0/10) is in DEFAULT_BLOCKED_V4 and is a classic
        // cloud metadata/relay path (review M2).
        "http://100.64.0.1/",
        // Host loopback carries staging redis-q and LiteLLM — plus the prod
        // proxies. A jail must never reach any of them.
        "http://127.0.0.1:16379/",
        "http://127.0.0.1:4000/",
      ];
      for (const url of blockedTargets) {
        const before = ruleCounter(nftTableText(), blockedPredicate);
        const res = await curlInJail(h, url);
        expect([28, 7], `${url} must be filtered (rc=${res.exitCode})`).toContain(res.exitCode);
        expect(
          ruleCounter(nftTableText(), blockedPredicate),
          `${url} must increment the uid-keyed blocked_v4 counter`,
        ).toBeGreaterThan(before);
      }

      // The box's own public gateway — the highest-value target.
      const ownBefore = ruleCounter(nftTableText(), ownPredicate);
      const own = await curlInJail(
        h,
        `http://${OWN_PUBLIC_IP}:${LIVE_GATEWAY_PORT}/cloud/v1/health`,
      );
      expect([28, 7], `own public IP must be filtered (rc=${own.exitCode})`).toContain(
        own.exitCode,
      );
      expect(ruleCounter(nftTableText(), ownPredicate)).toBeGreaterThan(ownBefore);

      // IPv6 half of the filter (review M2): ::1 is in DEFAULT_BLOCKED_V6.
      // The COUNTER is the proof, not curl's exit code — nothing listens on
      // ::1:16379, so an UNFILTERED connect would also fail (rc 7).
      const v6lo = await h.exec({ command: "cat /proc/net/if_inet6", timeoutMs: 20_000 });
      expect(
        v6lo.stdout,
        "IPv6 loopback (::1) must exist on the release host for the v6 egress proof",
      ).toContain("00000000000000000000000000000001");
      const v6 = await h.exec({
        command: "curl -6 -m 5 -s -o /dev/null http://[::1]:16379/",
        timeoutMs: 15_000,
      });
      expect([28, 7], `[::1] must be filtered (rc=${v6.exitCode})`).toContain(v6.exitCode);
      expect(
        ruleCounter(nftTableText(), blockedV6Predicate),
        "[::1] must increment the uid-keyed blocked_v6 counter",
      ).toBeGreaterThan(blockedV6Start);

      // Raw sockets cannot bypass the HTTP-client protections. Every denied
      // attempt must also move the appropriate uid-keyed counter.
      const rawProbePath = join(h.workspaceDir, "ovid-raw-probe.py");
      writeFileSync(rawProbePath, RAW_SOCKET_PY, { mode: 0o644 });
      chownSync(rawProbePath, UID, UID);
      const rawCases = [
        {
          name: "mapped loopback",
          address: "::ffff:127.0.0.1",
          port: 16_379,
          output: "raw-mapped-loopback.json",
          own: false,
        },
        {
          name: "own host",
          address: OWN_PUBLIC_IP,
          port: Number(LIVE_GATEWAY_PORT),
          output: "raw-own-host.json",
          own: true,
        },
        {
          name: "metadata",
          address: "169.254.169.254",
          port: 80,
          output: "raw-metadata.json",
          own: false,
        },
      ];
      for (const c of rawCases) {
        const beforeText = nftTableText();
        const beforeV4 = ruleCounter(beforeText, blockedPredicate);
        const beforeV6 = ruleCounter(beforeText, blockedV6Predicate);
        const beforeOwn = ruleCounter(beforeText, ownPredicate);
        const outcome = await rawSocketInJail(h, c.address, c.port, c.output);
        expect(outcome.rc, `${c.name} raw socket must time out: ${outcome.error}`).toBe(28);
        const afterText = nftTableText();
        if (c.own) {
          expect(
            ruleCounter(afterText, ownPredicate),
            `${c.name} must increment the own-IP deny counter`,
          ).toBeGreaterThan(beforeOwn);
        } else {
          const deniedDelta =
            ruleCounter(afterText, blockedPredicate) - beforeV4 +
            ruleCounter(afterText, blockedV6Predicate) - beforeV6;
          expect(deniedDelta, `${c.name} must increment a blocked-set deny counter`).toBeGreaterThan(0);
        }
      }

      // Force lifecycle scripts ON in a dependency-free local package. The
      // result files are mandatory; ignore-scripts/missing npm is not proof.
      const postDir = join(h.workspaceDir, "ovid-postinstall-proof");
      mkdirSync(postDir, { recursive: true });
      chownSync(postDir, UID, UID);
      const postHostCommand =
        `python3 raw_probe.py ${shSingle(OWN_PUBLIC_IP)} ${Number(LIVE_GATEWAY_PORT)} post-host.json`;
      const postMetadataCommand = "python3 raw_probe.py 169.254.169.254 80 post-metadata.json";
      writeFileSync(join(postDir, "raw_probe.py"), RAW_SOCKET_PY, { mode: 0o644 });
      writeFileSync(
        join(postDir, "package.json"),
        JSON.stringify({
          name: "ovid-staging-postinstall-proof",
          version: "1.0.0",
          private: true,
          scripts: { postinstall: `${postHostCommand} && ${postMetadataCommand}` },
        }),
        { mode: 0o644 },
      );
      chownSync(join(postDir, "raw_probe.py"), UID, UID);
      chownSync(join(postDir, "package.json"), UID, UID);
      const postBeforeText = nftTableText();
      const postBeforeOwn = ruleCounter(postBeforeText, ownPredicate);
      const postBeforeV4 = ruleCounter(postBeforeText, blockedPredicate);
      const postBeforeV6 = ruleCounter(postBeforeText, blockedV6Predicate);
      const postinstall = await h.exec({
        command:
          "cd /workspace/ovid-postinstall-proof && " +
          "npm install --ignore-scripts=false --offline --no-audit --no-fund --package-lock=false",
        timeoutMs: 60_000,
      });
      expect(postinstall.exitCode, `forced-on postinstall failed: ${postinstall.stderr}`).toBe(0);
      const postHost = JSON.parse(readFileSync(join(postDir, "post-host.json"), "utf8")) as {
        rc: number;
        error: string;
      };
      const postMetadata = JSON.parse(readFileSync(join(postDir, "post-metadata.json"), "utf8")) as {
        rc: number;
        error: string;
      };
      expect(postHost.rc, `postinstall own-host bypass: ${postHost.error}`).toBe(28);
      expect(postMetadata.rc, `postinstall metadata bypass: ${postMetadata.error}`).toBe(28);
      const postAfterText = nftTableText();
      expect(
        ruleCounter(postAfterText, ownPredicate),
        "postinstall own-host attempt must increment the own-IP counter",
      ).toBeGreaterThan(postBeforeOwn);
      const postDeniedDelta =
        ruleCounter(postAfterText, blockedPredicate) - postBeforeV4 +
        ruleCounter(postAfterText, blockedV6Predicate) - postBeforeV6;
      expect(postDeniedDelta, "postinstall metadata attempt must increment a blocked-set counter").toBeGreaterThan(0);

      // Control: allowed egress still works (the filter is not a blanket drop).
      const allowed = await h.exec({
        command: "curl -m 10 -sI -o /dev/null -w '%{http_code}' https://example.com",
        timeoutMs: 20_000,
      });
      expect(allowed.exitCode, allowed.stderr).toBe(0);
      expect(["200", "301", "302", "307", "308"]).toContain(allowed.stdout.trim());
    }),
    180_000,
  );

  it(
    title(
      "(5) pids.max — an in-jail fork storm stops at 64, leaves no host processes, and the live stack stays Up",
      baseGate,
    ),
    securityCase("pids.max enforcement", baseGate, async () => {
      const { handle: h, rawMgr: cg } = ctx();
      const envPath = cg.envPath(UID);
      // Keep the storm alive after the cap rejects a fork: the exec leaf (and
      // its pids.events) is torn down when the command exits, so the poll
      // below must overlap a still-running storm.
      const script =
        "import os, time\nwhile True:\n    try:\n        os.fork()\n    except OSError:\n        time.sleep(0.2)\n";
      const scriptPath = join(h.workspaceDir, "pids.py");
      writeFileSync(scriptPath, script, { mode: 0o644 });
      chownSync(scriptPath, UID, UID);

      // The file body bypasses layer 1 BY DESIGN — pids.max is the backstop.
      const storm = h.exec({
        command: "python3 /workspace/pids.py",
        timeoutMs: 10_000,
        maxOutputBytes: 4096,
      });
      const maxEvents = await untilAtLeast(
        async () => sumPidsMaxEvents(envPath),
        1,
        8_000,
      );
      const stormResult = await storm;
      expect(stormResult.exitCode, "the fork storm must not exit 0").not.toBe(0);
      expect(maxEvents, "pids.events must record the cap hit").toBeGreaterThanOrEqual(1);

      // The leaf teardown reaps the whole tree; no sandbox-uid process leaks.
      expect(await untilZero(() => scanForUid(UID), 10_000)).toBe(0);

      const host = spawnSync("sh", ["-c", "echo host-ok"], { encoding: "utf8", timeout: 10_000 });
      expect(host.status).toBe(0);
      expect(host.stdout.trim()).toBe("host-ok");
      assertLiveContainersUp();
    }),
    60_000,
  );

  it(
    title(
      "(6) memory.max — the 512 MiB cap OOM-kills the allocator (137), memory.peak stays bounded, the host is not drained",
      baseGate,
    ),
    securityCase("memory.max enforcement", baseGate, async () => {
      const { handle: h, rawMgr: cg } = ctx();
      const envPath = cg.envPath(UID);
      const script = [
        "chunks = []",
        "for _ in range(128):",
        "    chunks.append(b'x' * (8 * 1024 * 1024))",
        "import time",
        "time.sleep(60)",
      ].join("\n") + "\n";
      const scriptPath = join(h.workspaceDir, "mem.py");
      writeFileSync(scriptPath, script, { mode: 0o644 });
      chownSync(scriptPath, UID, UID);

      const beforeKb = memAvailableKb();
      const res = await h.exec({
        command: "python3 /workspace/mem.py",
        timeoutMs: 30_000,
        maxOutputBytes: 4096,
      });
      expect(
        res.exitCode,
        `allocator must be OOM-killed (137); timedOut=${res.timedOut} stderr=${res.stderr.slice(0, 200)}`,
      ).toBe(137);

      const events = await cg.readFile(envPath, "memory.events");
      const oomKill = Number(/^oom_kill (\d+)$/m.exec(events)?.[1] ?? "0");
      expect(oomKill, `memory.events:\n${events}`).toBeGreaterThanOrEqual(1);

      const peak = Number((await cg.readFile(envPath, "memory.peak")).trim());
      expect(peak).toBeLessThanOrEqual(512 * 1024 * 1024 * 1.05);

      const afterKb = memAvailableKb();
      // The bound must be ABOVE the jail's own cap: a 100 MB bound is
      // unsatisfiable by a 512 MiB allocator (and page-cache noise from the
      // live stack makes it worse). The property under test is "the host is
      // not drained", so the cap plus slack is the honest threshold.
      expect(
        beforeKb - afterKb,
        "host MemAvailable must not drop by more than the jail's 512 MiB cap + 64 MiB slack",
      ).toBeLessThan(512 * 1024 + 64 * 1024);
    }),
    90_000,
  );

  it(
    title(
      "(7) command-policy denylist — the in-jail PATH shims refuse every execution form (direct, shells, chains, pipes, env indirection, base64, path-qualified)",
      baseGate,
    ),
    securityCase("denylist execution", baseGate, async () => {
      const { handle: h } = ctx();
      let n = 0;
      for (const c of EXECUTION_DENYLIST_CORPUS) {
        n += 1;
        const file = `deny-${n}.sh`;
        const path = join(h.workspaceDir, file);
        // Writing the command to a file bypasses layer 1 by design; running
        // the file is the layer-2 (PATH shim) proof.
        writeFileSync(path, `${c.executionCommand ?? c.command}\n`, { mode: 0o644 });
        chownSync(path, UID, UID);
        const res = await h.exec({
          command: `sh ${file}`,
          timeoutMs: 30_000,
          maxOutputBytes: 8192,
        });
        expect(res.blocked, `${c.id}: the outer 'sh ${file}' is layer-1 allowed`).toBe(false);
        expect(
          res.stdout,
          `${c.id}: shim refusal copy missing (stderr=${JSON.stringify(res.stderr.slice(0, 200))})`,
        ).toContain(REFUSAL_MESSAGE);
        expect(res.exitCode, `${c.id}: shim must exit 126`).toBe(126);
      }
      expect(n, "the execution matrix must stay broad").toBeGreaterThan(100);
    }),
    600_000,
  );

  it(
    title(
      "(8) device & mount confinement — host devices are absent, mknod is refused, and the jail's mount namespace is private (host mounts unaffected)",
      baseGate,
    ),
    securityCase("device & mount confinement", baseGate, async () => {
      const { handle: h } = ctx();

      // bwrap `--dev /dev` builds a minimal devtmpfs: null/zero/full/
      // random/urandom/tty/console/ptmx only. Host devices must never appear.
      const dev = await h.exec({ command: "ls -1 /dev", timeoutMs: 20_000 });
      expect(dev.exitCode, dev.stderr).toBe(0);
      const names = dev.stdout.trim().split(/\s+/);
      for (const node of [
        "mem",
        "kmem",
        "port",
        "kvm",
        "sda",
        "sda1",
        "nvme0n1",
        "vda",
        "dm-0",
        "loop0",
      ]) {
        expect(names, `host device /dev/${node} is visible in the jail`).not.toContain(node);
      }
      for (const p of ["/dev/mem", "/dev/kvm", "/dev/sda", "/dev/loop0"]) {
        const st = await h.exec({ command: `stat -Lc '%d %i' ${p}`, timeoutMs: 20_000 });
        expect(st.exitCode, `${p} must not be visible`).not.toBe(0);
        expect(st.stderr).toMatch(/No such file/i);
      }

      // Creating a device node must be refused: /workspace is a host bind
      // owned by the initial user namespace, where the mapped root has no
      // CAP_MKNOD.
      const mknod = await h.exec({
        command: "mknod /workspace/devmem c 1 1",
        timeoutMs: 20_000,
      });
      expect(mknod.exitCode, "mknod must not create a device node").not.toBe(0);
      expect(mknod.stderr).toMatch(/Operation not permitted|Permission denied|Invalid argument/i);
      expect(existsSync(join(h.workspaceDir, "devmem")), "mknod created a host file").toBe(false);

      // Mount namespace: the exec's mount namespace inode must differ from
      // the test process's (host) mount namespace.
      const hostMntNs = statSync("/proc/self/ns/mnt").ino;
      const jailMntNs = await h.exec({
        command: "stat -Lc %i /proc/self/ns/mnt",
        timeoutMs: 20_000,
      });
      expect(jailMntNs.exitCode, jailMntNs.stderr).toBe(0);
      expect(Number(jailMntNs.stdout.trim())).not.toBe(hostMntNs);

      // Host mount points must not leak into the jail's mount table. (The
      // rootfs SOURCE path is allowed — it is the jail's `/` bind.)
      const mountinfo = await h.exec({
        command: "cat /proc/self/mountinfo",
        timeoutMs: 20_000,
      });
      expect(mountinfo.exitCode, mountinfo.stderr).toBe(0);
      for (const marker of [
        "/workspaces/users",
        "/workspaces-staging",
        "/var/lib/docker",
        "/mnt/ovid-pressure",
      ]) {
        expect(mountinfo.stdout, `host mount leaked: ${marker}`).not.toContain(marker);
      }
      expect(mountinfo.stdout).toContain(" /workspace ");
      expect(mountinfo.stdout).toContain(" /root ");

      // mount/umount/pivot_root attempts may succeed INSIDE the jail's own
      // throwaway mount namespace — that is not an escape. The HOST mount
      // table must be byte-identical afterwards.
      const hostMountinfo = readFileSync("/proc/self/mountinfo", "utf8");
      const attempts = [
        "umount /workspace",
        "mkdir -p /workspace/mnt && mount -t tmpfs none /workspace/mnt",
        "mkdir -p /workspace/newroot /workspace/put_old && pivot_root /workspace/newroot /workspace/put_old",
      ];
      for (const command of attempts) {
        // No exit-code assertion: the attempt is the evidence, and the
        // required property is confinement to the jail's own namespace.
        await h.exec({ command, timeoutMs: 20_000 });
      }
      expect(
        readFileSync("/proc/self/mountinfo", "utf8"),
        "the HOST mount namespace changed during mount/umount/pivot_root attempts",
      ).toBe(hostMountinfo);
    }),
    120_000,
  );
});
