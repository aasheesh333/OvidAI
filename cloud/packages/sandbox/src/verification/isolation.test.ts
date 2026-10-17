import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  rmdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { quote } from "shell-quote";
import { createCgroupManager, type CgroupManager } from "../cgroups.js";
import {
  DEFAULT_SANDBOX_LIMITS,
  loadSandboxConfig,
  type SandboxConfig,
} from "../config.js";
import { ALLOWED_COMMAND_CORPUS, BLOCKED_COMMAND_CORPUS, PATH_ESCAPE_CORPUS } from "../corpora.js";
import { renderEtcBundle } from "../etcFiles.js";
import { hostTestsAvailable, jailMechanismAvailable } from "../hostGate.js";
import { buildBwrapArgs, type JailSpec } from "../invocation.js";
import { createSetuidLauncher } from "../launcher.js";
import {
  createSandboxManager,
  type SandboxHandle,
  type SandboxManager,
} from "../manager.js";
import { runEgressNetnsProof } from "../netTestKit.js";
import { REFUSAL_MESSAGE } from "../policy.js";
import type { PtySession } from "../pty.js";
import { createNoopQuotaBackend } from "../quota.js";
import { renderCli } from "../renderNftCli.js";
import { resolveRootfs, type ResolvedRootfs } from "../rootfs.js";

/**
 * P2 Task 15 — the ISOLATION ACCEPTANCE SUITE: the phase acceptance gate,
 * one command that proves spec §7/§11 on the real sandbox host.
 *
 * Cross-references (the confinement story is proven at TWO layers):
 * - TOOL-side confinement (run_shell rejecting path-escape and blocked
 *   commands BEFORE any jail exists) is pinned by Task 12's portable tests
 *   in apps/worker — packages never import apps, and this suite never
 *   re-lists corpus commands: cloud/packages/sandbox/src/corpora.ts (Task 4)
 *   stays the single source for blocked/allowed/path-escape entries.
 * - This suite proves the JAIL-side guarantees (§7 layers 2/3 + §11): what a
 *   payload that DID reach a jail can see, write, spawn, and reach on the
 *   network.
 *
 * Structure (one `it` per numbered guarantee):
 * - "jail guarantees (host-gated)" — guarantees 1–8. Runs only when
 *   OVID_SANDBOX_HOST_TESTS=1 + root + a working bwrap mechanism
 *   (jailMechanismAvailable — bwrap is NOT installed until the owner-gated
 *   Task-1 probe runs, so this describe gate-skips on a dev box).
 * - "nft golden drift (portable)" — guarantee 7's renderer-drift check
 *   (pure; runs everywhere so renderer changes can never drift silently).
 * - "rootfs hygiene (portable)" — guarantee 9, gated only on a rootfs
 *   source (OVID_ROOTFS, or the newest dist/*.tar.zst extracted to scratch).
 * - "refusal copy parity (portable)" — guarantee 10 (grep-style file reads).
 *
 * Scope guard (plan Global Constraints): the host-gated half uses a
 * throwaway `ovid-probe-acc-{pid}` cgroup base + mkdtemp workspaces root
 * only, full cleanup in afterAll with an explicit no-leftovers assertion.
 * Production cgroup paths are never touched. The netns proof runs inside a
 * disposable `ovid-spike-egress-*` namespace owned by the shared kit.
 */

const THIS_DIR = fileURLToPath(new URL(".", import.meta.url));
/** Source files read grep-style for the copy-parity guarantee (10). */
const POLICY_TS = join(THIS_DIR, "..", "policy.ts");
const SHIMS_SRC_DIR = join(THIS_DIR, "..", "..", "..", "..", "deploy", "rootfs", "shims");
const ROOTFS_DIST_DIR = join(THIS_DIR, "..", "..", "..", "..", "deploy", "rootfs", "dist");
const WORKER_SYSTEM_PROMPT_TS = join(
  THIS_DIR, "..", "..", "..", "..", "apps", "worker", "src", "tools", "systemPrompt.ts",
);
/** Committed golden ruleset for guarantee 7's drift check. */
const GOLDEN_NFT = join(THIS_DIR, "nft-golden.txt");

/**
 * The 13 Task 3 PATH shims + the 9 unconditional blockers, mirroring
 * shims.test.ts (Task 3's pinned contract — this is the shim ROSTER, not a
 * command corpus; corpora.ts remains the single source for commands).
 */
const ALL_SHIMS = [
  "gcc",
  "g++",
  "make",
  "gradle",
  "gradlew",
  "kotlinc",
  "javac",
  "sdkmanager",
  "ndk-build",
  "cargo",
  "docker",
  "flutter",
  "ovid",
] as const;
const UNCONDITIONAL_SHIMS = ALL_SHIMS.slice(0, 9);

/** Guarantee 9: no compiler/JVM binary may exist anywhere in the rootfs. */
const BANNED_ROOTFS_BINARIES = ["javac", "java", "gcc", "g++", "make", "gradle", "kotlinc"] as const;

// ---------------------------------------------------------------------------
// shared helpers (host-test conventions from the Task 7/8/9 host suites)
// ---------------------------------------------------------------------------

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function readProcSelfCgroup(): string {
  const line = readFileSync("/proc/self/cgroup", "utf8")
    .trim()
    .split("\n")
    .find((l) => l.startsWith("0::"));
  if (!line) throw new Error("not a cgroups v2 host: no 0:: line in /proc/self/cgroup");
  return line.slice(3);
}

function readProcs(cgroupPath: string): number[] {
  try {
    return readFileSync(join(cgroupPath, "cgroup.procs"), "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(Number);
  } catch {
    return []; // cgroup gone
  }
}

/** Host processes whose /proc/<pid>/cmdline contains `marker`. */
function scanForMarker(marker: string): number {
  let n = 0;
  for (const entry of readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      if (readFileSync(join("/proc", entry, "cmdline"), "utf8").includes(marker)) n++;
    } catch {
      /* process gone between readdir and read */
    }
  }
  return n;
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
    await sleep(100);
    v = fn();
  }
  return v;
}

async function untilAtLeast(fn: () => number, target: number, ms: number): Promise<number> {
  const deadline = Date.now() + ms;
  let v = fn();
  while (v < target && Date.now() < deadline) {
    await sleep(50);
    v = fn();
  }
  return v;
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
    await sleep(50);
  }
  rmdirSync(path);
}

/** Decoded text of a session's whole retained scrollback. */
function ringText(session: PtySession): string {
  return session.ring
    .since(null)
    .chunks.map((c) => Buffer.from(c.data, "base64").toString("utf8"))
    .join("");
}

function countRefusals(text: string): number {
  return text.split(REFUSAL_MESSAGE).length - 1;
}

/** Polls until the ring text carries at least `n` refusal copies. */
async function untilRefusalCount(get: () => string, n: number, ms: number): Promise<void> {
  const deadline = Date.now() + ms;
  while (countRefusals(get()) < n) {
    if (Date.now() > deadline) {
      throw new Error(
        `timeout waiting for refusal copy #${n} in pty ring; last output: ${JSON.stringify(get().slice(-400))}`,
      );
    }
    await sleep(50);
  }
}

/** Single-quote a shell word. */
function shSingle(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function sha256(data: Buffer | string): string {
  return createHash("sha256").update(data).digest("hex");
}

function netnsToolsAvailable(): boolean {
  for (const tool of ["nft", "ip", "curl", "python3", "setpriv"]) {
    if (spawnSync("sh", ["-c", `command -v ${tool}`]).status !== 0) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// host-gated configuration (guarantees 1–8)
// ---------------------------------------------------------------------------

const UID = 200095;
const CG_ROOT = "/sys/fs/cgroup";
const BASE = `ovid-probe-acc-${process.pid}`;
const ORIGINAL_CGROUP = readProcSelfCgroup();

/**
 * Probe config: throwaway cgroup base, real launcher, and env limits
 * overridden SMALL (64 MiB memory, 16 pids) so the guarantee-6 hogs run
 * double-bounded — even with zero enforcement they could never hurt the box.
 */
const cfg: SandboxConfig = {
  ...loadSandboxConfig({}),
  rootfsPath: process.env.OVID_ROOTFS ?? "/tmp/ovid-rootfs-test",
  cgroupRoot: CG_ROOT,
  cgroupBase: BASE,
  launch: "setuid",
  limits: {
    ...DEFAULT_SANDBOX_LIMITS,
    memoryMaxBytes: 64 * 1024 * 1024,
    pidsMax: 16,
  },
};

const rawMgr: CgroupManager = createCgroupManager({ cgroupRoot: CG_ROOT, cgroupBase: BASE });

function moveSelfTo(cgroupPath: string): void {
  writeFileSync(join(CG_ROOT, cgroupPath, "cgroup.procs"), String(process.pid));
}

/**
 * die-with-parent fixture (guarantee 8): a plain node child that spawns the
 * jail via the sandbox-enter.sh launcher contract (NUL-separated argv file →
 * `bash sandbox-enter.sh <procs> <uid> <gid> <argvfile>`). Dependency-free on
 * purpose — the child must not import the (possibly stale) dist build. Same
 * proven shape as the Task 7 host suite.
 */
const DWP_SCRIPT = `
const { spawn } = require("node:child_process");
const { mkdtempSync, writeFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const spec = JSON.parse(process.env.OVID_DWP_SPEC);
const scratch = mkdtempSync(join(tmpdir(), "ovid-dwp-"));
const argvFile = join(scratch, "argv");
writeFileSync(argvFile, spec.bwrapArgv.join("\\0") + "\\0", { mode: 0o600 });
const child = spawn("bash", [spec.launcherPath, spec.procsFile, String(spec.uid), String(spec.gid), argvFile], { cwd: spec.cwd, stdio: ["ignore", "pipe", "pipe"] });
child.stdout.resume();
child.stderr.resume();
child.on("exit", () => { try { rmSync(scratch, { recursive: true, force: true }); } catch {} });
setInterval(() => {}, 1 << 30); // stay alive while the jail runs
`;

// ---------------------------------------------------------------------------
// guarantees 1–8: the jail-side acceptance (host-gated in full)
// ---------------------------------------------------------------------------

describe.skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg))(
  "isolation acceptance — jail guarantees (host-gated)",
  () => {
    let manager: SandboxManager;
    let handle: SandboxHandle;
    let wsRoot: string;
    let rootfs: ResolvedRootfs;
    let hostPasswdHash: string | null = null;
    const scratchDirs: string[] = [];

    beforeAll(async () => {
      // Guarantee 4 anchor: the HOST's /etc/passwd, hashed before anything ran.
      hostPasswdHash = sha256(readFileSync("/etc/passwd"));

      wsRoot = mkdtempSync(join(tmpdir(), "ovid-acc-ws-"));
      scratchDirs.push(wsRoot);

      await rawMgr.init();
      // init() parked this process in the probe base's worker leaf; move it
      // back out so the vitest tree does not live in the throwaway cgroup.
      moveSelfTo(ORIGINAL_CGROUP);

      rootfs = await resolveRootfs(cfg.rootfsPath);
      manager = createSandboxManager({
        config: { ...cfg, workspacesRoot: wsRoot },
        // Stub allocator: the manager treats it as the idempotent prod seam.
        allocateUid: async () => UID,
        cgroups: rawMgr,
        // Noop-safe quota (XFS prjquota activates at Task 16).
        quota: createNoopQuotaBackend(),
        launcher: createSetuidLauncher(cfg),
        rootfs,
      });
      // One env for the fixed test uid, small limits (see cfg).
      handle = await manager.attach("acceptance-user");
    }, 60_000);

    afterAll(async () => {
      const problems: string[] = [];
      try {
        await manager.close(); // destroys the env + removes everything
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
      // Defensive sweep — scoped to THIS suite's base prefix only: sibling
      // probe suites may be running in parallel against their own bases.
      for (const entry of readdirSync(CG_ROOT)) {
        if (!entry.startsWith("ovid-probe-acc-")) continue;
        try {
          await removeCgroupTree(join(CG_ROOT, entry), process.pid);
        } catch (e) {
          problems.push(`sweep ${entry}: ${String(e)}`);
        }
      }
      const leftovers = readdirSync(CG_ROOT).filter((e) => e.startsWith("ovid-probe-acc-"));
      if (leftovers.length > 0) problems.push(`leftover probe cgroups: ${leftovers.join(", ")}`);

      for (const dir of scratchDirs) {
        try {
          rmSync(dir, { recursive: true, force: true });
        } catch (e) {
          problems.push(`rm ${dir}: ${String(e)}`);
        }
      }
      // dwp scratch dirs are owned by the (killed) node children — sweep.
      for (const entry of readdirSync(tmpdir())) {
        if (!entry.startsWith("ovid-dwp-")) continue;
        try {
          rmSync(join(tmpdir(), entry), { recursive: true, force: true });
        } catch {
          /* best effort */
        }
      }
      const tmpLeftovers = readdirSync(tmpdir()).filter(
        (e) => e.startsWith("ovid-acc-") || e.startsWith("ovid-dwp-"),
      );
      if (tmpLeftovers.length > 0) {
        problems.push(`leftover scratch dirs: ${tmpLeftovers.join(", ")}`);
      }
      // No sandbox-uid processes may survive the suite.
      try {
        if ((await untilZero(() => scanForUid(UID), 5_000)) !== 0) {
          problems.push(`leftover uid-${UID} processes: ${scanForUid(UID)}`);
        }
      } catch (e) {
        problems.push(`uid scan: ${String(e)}`);
      }
      // Guarantee 4 (byte-identity): the HOST's /etc/passwd is unchanged.
      if (hostPasswdHash !== null) {
        try {
          const after = sha256(readFileSync("/etc/passwd"));
          if (after !== hostPasswdHash) {
            problems.push("HOST /etc/passwd changed during the suite (guarantee 4)");
          }
        } catch (e) {
          problems.push(`host passwd re-hash: ${String(e)}`);
        }
      }
      if (problems.length > 0) {
        throw new Error(`isolation acceptance cleanup failed:\n- ${problems.join("\n- ")}`);
      }
    });

    it(
      "(1) path confinement — escape corpus fails or hits only the sandbox's private /etc; RO root; /workspaces absent; only /workspace, /root, /tmp writable",
      async () => {
        // The jail-side reading of PATH_ESCAPE_CORPUS (whose tool-side
        // meaning is "resolves outside the workspace root"): a cat through
        // the entry must fail/produce nothing, or land EXACTLY on the
        // sandbox's own private /etc/passwd (the ro-bound per-sandbox copy —
        // reading one's own /etc is by design; what may never happen is
        // reaching the HOST's files, pinned below and by guarantee 4).
        const jailPasswd = renderEtcBundle({ dns: cfg.sandboxDns }).passwd;
        const hostPasswd = readFileSync("/etc/passwd", "utf8");
        for (const entry of PATH_ESCAPE_CORPUS) {
          const res = await handle.exec({
            command: `cat ${quote([entry])}`,
            stdin: "",
            timeoutMs: 20_000,
          });
          const failed = res.exitCode !== 0 || res.stdout === "";
          const privateEtcOnly = res.exitCode === 0 && res.stdout === jailPasswd;
          if (!failed && !privateEtcOnly) {
            throw new Error(
              `path escape ${JSON.stringify(entry)} read jail content beyond the sandbox's ` +
                `private /etc (exit=${res.exitCode}, stdout=${JSON.stringify(res.stdout.slice(0, 120))})`,
            );
          }
          if (res.exitCode === 0 && res.stdout !== "") {
            // A successful read must never disclose the HOST's passwd.
            expect(
              res.stdout,
              `entry ${JSON.stringify(entry)} leaked host /etc/passwd`,
            ).not.toBe(hostPasswd);
          }
        }

        // Writes to the read-only surfaces fail EROFS. (/opt: the built noble
        // rootfs ships an EMPTY /opt — task-7 recorded deviation — so ENOENT
        // is equally acceptable there; the host /opt is what must not leak.)
        const roTargets: Array<[string, RegExp]> = [
          ["/acc-pwn", /read-only/i],
          ["/etc/acc-pwn", /read-only/i],
          ["/usr/acc-pwn", /read-only/i],
          ["/root/../acc-pwn", /read-only/i],
          ["/opt/acc-pwn", /read-only|No such file/i],
        ];
        for (const [path, pat] of roTargets) {
          const r = await handle.exec({ command: `touch ${path}`, timeoutMs: 20_000 });
          expect(r.exitCode, `write to ${path} must fail`).not.toBe(0);
          expect(r.stderr, `write to ${path}`).toMatch(pat);
        }

        // The HOST workspaces tree does not exist inside the jail.
        const wsLs = await handle.exec({ command: "ls /workspaces", timeoutMs: 15_000 });
        expect(wsLs.exitCode).not.toBe(0);
        expect(wsLs.stderr).toMatch(/No such file/i);
        // /opt: ENOENT or empty (no HOST /opt content leaks in).
        const optLs = await handle.exec({ command: "ls /opt", timeoutMs: 15_000 });
        if (optLs.exitCode === 0) {
          expect(optLs.stdout.trim()).toBe("");
        } else {
          expect(optLs.stderr).toMatch(/No such file/i);
        }

        // Exactly /workspace, /root and /tmp are writable.
        const w = await handle.exec({
          command: "touch /workspace/acc-w1 /root/acc-w2 /tmp/acc-w3",
          timeoutMs: 15_000,
        });
        expect(w.exitCode, w.stderr).toBe(0);
      },
      240_000,
    );

    it(
      "(2) blocked commands — layer 1 (zero side effects), layer 2 shim, and direct in-terminal PTY forms all refuse",
      async () => {
        // Layer 1: refused before any spawn, exact copy, zero cgroup effects.
        for (const entry of BLOCKED_COMMAND_CORPUS) {
          if (entry.expect !== "layer1") continue;
          const before = await rawMgr.listChildren(rawMgr.envPath(UID));
          const r = await handle.exec({ command: entry.command });
          expect(r.blocked, JSON.stringify(entry.command)).toBe(true);
          expect(r.refusal, JSON.stringify(entry.command)).toBe(REFUSAL_MESSAGE);
          expect(r.exitCode).toBeNull();
          expect(r.stdout).toBe("");
          expect(r.stderr).toBe("");
          expect(
            await rawMgr.listChildren(rawMgr.envPath(UID)),
            `layer-1 refusal must create no leaf for ${JSON.stringify(entry.command)}`,
          ).toEqual(before);
        }

        // Layer 2 boundary: the corpus's shim entries RUN — and the PATH
        // shim inside the jail refuses with the same copy, exit 126.
        for (const entry of BLOCKED_COMMAND_CORPUS) {
          if (entry.expect !== "shim") continue;
          const r = await handle.exec({ command: entry.command, timeoutMs: 30_000 });
          expect(r.blocked, JSON.stringify(entry.command)).toBe(false);
          expect(r.exitCode, JSON.stringify(entry.command)).toBe(126);
          expect(r.stdout, JSON.stringify(entry.command)).toContain(REFUSAL_MESSAGE);
        }

        // Direct in-terminal forms (Review Focus #1): a REAL PTY, commands
        // typed at the interactive shell — the tool layer is bypassed by
        // design, so the layer-2 shim is the only defense. The three shapes
        // come from the corpus (never re-listed): plain word, subcommand
        // form, and a bash -c wrapper.
        const ptyForms = ["make", "gradle build", "bash -c 'gcc x.c'"];
        for (const f of ptyForms) {
          expect(
            BLOCKED_COMMAND_CORPUS.some((e) => e.command === f),
            `corpus must keep the in-terminal form ${JSON.stringify(f)}`,
          ).toBe(true);
        }
        const session = await handle.createPty(
          { sessionId: "acc-pty" },
          { onData: () => {}, onExit: () => {} },
        );
        try {
          // Warm up: the shell is up once `tty` answers.
          session.write(Buffer.from("tty\n"));
          const deadline = Date.now() + 15_000;
          while (!ringText(session).includes("/dev/pts/")) {
            if (Date.now() > deadline) {
              throw new Error(
                `pty warm-up timeout; ring: ${JSON.stringify(ringText(session).slice(-400))}`,
              );
            }
            await sleep(50);
          }
          for (const f of ptyForms) {
            const n = countRefusals(ringText(session));
            session.write(Buffer.from(`${f}\n`));
            await untilRefusalCount(() => ringText(session), n + 1, 15_000);
          }
        } finally {
          await session.kill();
        }
      },
      300_000,
    );

    it(
      "(3) allowlist — every allowed corpus entry spawns (blocked:false; exit code irrelevant — missing binaries are fine)",
      async () => {
        for (const command of ALLOWED_COMMAND_CORPUS) {
          const r = await handle.exec({ command, timeoutMs: 20_000 });
          expect(
            r.blocked,
            `allowlist must not block ${JSON.stringify(command)}`,
          ).toBe(false);
        }
      },
      420_000,
    );

    it("(4) uid map + ownership — (0, uid, 1), id -u 0 inside, host files land as uid, own /etc/passwd RO, host passwd untouched", async () => {
      const uidMap = await handle.exec({ command: "cat /proc/self/uid_map" });
      expect(uidMap.exitCode).toBe(0);
      expect(uidMap.stdout.trim()).toBe(`0 ${UID} 1`);
      const idu = await handle.exec({ command: "id -u" });
      expect(idu.exitCode).toBe(0);
      expect(idu.stdout.trim()).toBe("0"); // mapped root INSIDE only
      // Files created inside land host-owned by the sandbox uid.
      const t = await handle.exec({ command: "touch /workspace/acc-owned.txt" });
      expect(t.exitCode).toBe(0);
      expect(statSync(join(handle.workspaceDir, "acc-owned.txt")).uid).toBe(UID);
      // Writing the jail's own /etc/passwd fails (ro-bind of the private etc).
      const etcWrite = await handle.exec({ command: "sh -c 'echo pwn > /etc/passwd'" });
      expect(etcWrite.exitCode).not.toBe(0);
      expect(etcWrite.stderr).toMatch(/read-only/i);
      // The HOST /etc/passwd byte-identity is asserted in afterAll (hash
      // before/after the whole suite).
    }, 60_000);

    it("(5) pid isolation — the test runner is invisible in the jail; /proc/self/cgroup carries sandbox-{uid}", async () => {
      const cg = await handle.exec({ command: "cat /proc/self/cgroup" });
      expect(cg.exitCode).toBe(0);
      expect(cg.stdout).toContain(`sandbox-${UID}`);
      // ps -e inside the jail (fallback: /proc walk) must not list the test
      // runner's pid — the jail has its own pid namespace.
      let text: string;
      const ps = await handle.exec({ command: "ps -e", timeoutMs: 15_000 });
      if (ps.exitCode === 0) {
        text = ps.stdout;
      } else {
        const proc = await handle.exec({
          command: 'for p in /proc/[0-9]*; do echo ${p#/proc/}; done',
          timeoutMs: 15_000,
        });
        expect(proc.exitCode, proc.stderr).toBe(0);
        text = proc.stdout;
      }
      const pids = text
        .trim()
        .split("\n")
        .map((line) => line.trim().split(/\s+/)[0])
        .filter((p) => /^\d+$/.test(p));
      expect(pids.length).toBeGreaterThan(0);
      expect(pids.length, `jail must see a handful of processes, got: ${pids}`).toBeLessThanOrEqual(10);
      expect(pids, "the test runner must not be visible in the jail").not.toContain(
        String(process.pid),
      );
    }, 60_000);

    it(
      "(6) resource caps — memory hog OOM-killed (137), in-jail fork bomb contained by pids.max, host unaffected, job tree-kill leaves zero markers",
      async () => {
        // Memory: a double-bounded hog (allocates at most 128 MiB) under the
        // env's 64 MiB cap → the cgroup OOM killer SIGKILLs it (exit 137).
        const py = [
          "total = 0",
          "chunks = []",
          "while total < 128 * 1024 * 1024:",
          '    chunks.append(b"x" * (8 * 1024 * 1024))',
          "    total += 8 * 1024 * 1024",
          "import time",
          "time.sleep(300)",
        ].join("\n");
        const hog = await handle.exec(
          { command: `python3 -c ${shSingle(py)}`, timeoutMs: 30_000 },
        );
        expect(hog.exitCode).toBe(137); // 128 + SIGKILL
        const memEvents = await rawMgr.readFile(rawMgr.envPath(UID), "memory.events");
        expect(
          parseInt(memEvents.match(/^oom_kill (\d+)$/m)?.[1] ?? "0", 10),
          `memory.events must record the OOM kill:\n${memEvents}`,
        ).toBeGreaterThanOrEqual(1);

        // Fork bomb, WRITTEN TO A FILE and executed via `sh bomb.sh` —
        // bypasses layer 1 by design (the file body is never policy-parsed),
        // so pids.max (16) is the only defense. The bomb's parent shell may
        // exit immediately while the recursive pipelines daemonize —
        // containment, not the exit code, is the guarantee: the leaf is
        // tree-killed by the exec teardown, pids.events records the cap hit.
        writeFileSync(join(handle.workspaceDir, "bomb.sh"), ":(){ :|:& };:\n");
        await handle.exec({
          command: "sh bomb.sh",
          timeoutMs: 15_000,
          maxOutputBytes: 4096,
        });
        const envPath = rawMgr.envPath(UID);
        let maxEvents = 0;
        {
          const deadline = Date.now() + 10_000;
          for (;;) {
            const events = await rawMgr.readFile(envPath, "pids.events");
            const m = events.match(/^max (\d+)$/m);
            maxEvents = m ? Number(m[1]) : 0;
            if (maxEvents >= 1) break;
            if (Date.now() > deadline) {
              throw new Error(`timeout waiting for pids.events max, got:\n${events}`);
            }
            await sleep(100);
          }
        }
        expect(maxEvents).toBeGreaterThanOrEqual(1); // Review Focus #4
        // The suite's own subsequent spawn still works (in-jail …).
        const after = await handle.exec({ command: "echo host-alive", timeoutMs: 20_000 });
        expect(after.exitCode, after.stderr).toBe(0);
        expect(after.stdout.trim()).toBe("host-alive");
        // … and the host itself is unaffected by the storm.
        const hostEcho = spawnSync("sh", ["-c", "echo host-ok"], { encoding: "utf8", timeout: 10_000 });
        expect(hostEcho.status).toBe(0);
        expect(hostEcho.stdout.trim()).toBe("host-ok");

        // Job tree-kill: a backgrounded grandchild dies with its job leaf —
        // zero marker processes remain.
        const rand = randomBytes(4).toString("hex");
        const marker = `accmark-${rand}`;
        const info = await handle.jobs.start({
          command: `(sleep 300 ${marker} &) ; sleep 300 ${marker}`,
        });
        expect(await untilAtLeast(() => scanForMarker(marker), 2, 15_000)).toBeGreaterThanOrEqual(2);
        await handle.jobs.kill(info.id);
        expect(await untilZero(() => scanForMarker(marker), 2_000)).toBe(0);
      },
      180_000,
    );

    it.skipIf(!netnsToolsAvailable())(
      "(7) egress — uid-keyed nft filter proven in a disposable netns (rc 28, counter, root rc 0, metadata path)",
      async () => {
        // Shared kit (Task 11): renders the ruleset for exactly [uid, uid],
        // loads it inside a disposable netns, and tears everything down. The
        // 169.254.169.254 counter-increment is asserted in-kit (it throws).
        const proof = await runEgressNetnsProof({ ownPublicIp: "203.0.113.7", uid: 200050 });
        // Loopback is inside blocked 127.0.0.0/8 → curl as the uid times out.
        expect(proof.blockedRc).toBe(28);
        // The deny rule fired at the output hook — the block is the filter's doing.
        expect(proof.counterPackets).toBeGreaterThan(0);
        // Root reaches the SAME listener — the drop is keyed on the uid.
        expect(proof.rootRc).toBe(0);
        // The metadata path also lands on the blocked_v4 rule.
        expect(proof.metadataBlockedRc).toBe(28);
        // The renderer-drift half of this guarantee (committed golden) is the
        // portable "(7 drift)" test below — it runs on every CI box.
      },
      90_000,
    );

    it(
      "(8) die-with-parent — SIGKILLing the launcher parent reaps the jail within 2 s",
      async () => {
        const rand = randomBytes(4).toString("hex");
        const marker = `sleep 300 accdwp-${rand}`;
        const leaf = await rawMgr.createLeaf(UID, `exec-dwp-${rand}`);
        // The manager's env layout: {workspacesRoot}/{uid}/etc is the private
        // etcDir the jail spec needs.
        const spec: JailSpec = {
          rootfs: rootfs.path,
          workspaceDir: handle.workspaceDir,
          homeDir: handle.homeDir,
          etcDir: join(wsRoot, String(UID), "etc"),
          // exec -a rewrites argv[0] so the sleeper is findable by marker in
          // host /proc/<pid>/cmdline.
          argv: ["bash", "-c", `exec -a ${shSingle(marker)} sleep 300`],
        };
        const nodeChild = spawn(process.execPath, ["-e", DWP_SCRIPT], {
          env: {
            ...process.env,
            OVID_DWP_SPEC: JSON.stringify({
              launcherPath: cfg.launcherPath,
              procsFile: rawMgr.procsFile(leaf),
              uid: UID,
              gid: UID,
              cwd: handle.workspaceDir,
              bwrapArgv: buildBwrapArgs(spec, cfg),
            }),
          },
          stdio: ["ignore", "pipe", "pipe"],
        });
        try {
          // The jail is up once the marker process exists on the host.
          expect(await untilAtLeast(() => scanForMarker(marker), 1, 10_000)).toBeGreaterThanOrEqual(1);
          nodeChild.kill("SIGKILL");
          // bwrap --die-with-parent: the whole jail dies with the node child.
          expect(await untilZero(() => scanForMarker(marker), 2_000)).toBe(0);
        } finally {
          try {
            nodeChild.kill("SIGKILL");
          } catch {
            /* already gone */
          }
          await rawMgr.kill(leaf).catch(() => {});
        }
      },
      60_000,
    );
  },
);

// ---------------------------------------------------------------------------
// guarantee 7 (drift half) — portable: the committed golden ruleset
// ---------------------------------------------------------------------------

describe("isolation acceptance — nft golden drift (portable)", () => {
  it("(7 drift) renderCli({...}) === the committed nft-golden.txt", () => {
    // Pinned render inputs (controller ruling): the drift check must compare
    // against a COMMITTED artifact so an unintended renderer change fails CI.
    // Regenerate the golden DELIBERATELY (and only) when the renderer changes
    // by design: re-render with these exact env values and commit the file.
    const golden = readFileSync(GOLDEN_NFT, "utf8");
    const rendered = renderCli({
      OVID_PUBLIC_IP: "203.0.113.7",
      OVID_SANDBOX_UID_BASE: "200000",
    });
    expect(rendered).toBe(golden);
  });
});

// ---------------------------------------------------------------------------
// guarantee 9 — rootfs hygiene (portable, gated only on a rootfs source)
// ---------------------------------------------------------------------------

/**
 * The rootfs source for hygiene: OVID_ROOTFS when set (the probe run points
 * it at an extracted tree), else the NEWEST dist/*.tar.zst extracted to a
 * scratch dir — self-contained and version-correct (never a stale /tmp
 * extract). Null → the describe skips.
 */
function rootfsSource():
  | { kind: "env"; path: string }
  | { kind: "tarball"; tarball: string }
  | null {
  const env = process.env.OVID_ROOTFS;
  if (env !== undefined && env !== "") {
    return existsSync(env) ? { kind: "env", path: env } : null;
  }
  let tarball: string | null = null;
  try {
    const tars = readdirSync(ROOTFS_DIST_DIR)
      .filter((n) => /\.tar\.zst$/.test(n))
      .sort(); // names sort by build date + revision — last = newest
    if (tars.length > 0) tarball = join(ROOTFS_DIST_DIR, tars[tars.length - 1]);
  } catch {
    return null; // no dist dir in this checkout
  }
  if (tarball === null) return null;
  if (spawnSync("sh", ["-c", "command -v zstd && command -v tar"]).status !== 0) return null;
  return { kind: "tarball", tarball };
}

describe.skipIf(rootfsSource() === null)(
  "isolation acceptance — rootfs hygiene (portable, artifact-gated)",
  () => {
    let rootfsDir = "";
    let scratchDir: string | null = null;
    let sourceName = "";

    beforeAll(async () => {
      const src = rootfsSource();
      if (src === null) throw new Error("rootfs source disappeared between gate and setup");
      if (src.kind === "env") {
        rootfsDir = src.path;
        sourceName = `OVID_ROOTFS=${src.path}`;
        return;
      }
      sourceName = basename(src.tarball);
      scratchDir = mkdtempSync(join(tmpdir(), "ovid-rootfs-hyg-"));
      // zstd -dc | tar -x (docker-export layer tarballs carry the tree at
      // the archive root — no top-level directory to strip).
      const r = spawnSync(
        "bash",
        ["-c", `zstd -dc ${shSingle(src.tarball)} | tar -x -C ${shSingle(scratchDir)}`],
        { timeout: 300_000, encoding: "utf8" },
      );
      if (r.status !== 0) {
        throw new Error(
          `rootfs hygiene: extracting ${src.tarball} failed (rc=${r.status}): ${r.stderr.trim() || r.stdout.trim()}`,
        );
      }
      rootfsDir = scratchDir;
    }, 360_000);

    afterAll(() => {
      if (scratchDir !== null) {
        rmSync(scratchDir, { recursive: true, force: true });
      }
      const leftovers = readdirSync(tmpdir()).filter((e) => e.startsWith("ovid-rootfs-hyg-"));
      expect(leftovers, "rootfs hygiene scratch dirs must be cleaned").toEqual([]);
    });

    it("(9a) no compiler/JVM binaries anywhere under the rootfs (walk + basename set, the 13 PATH shims excluded)", () => {
      const banned = new Set<string>(BANNED_ROOTFS_BINARIES);
      // The Task 3 PATH shims in usr/local/bin are the DELIBERATE occupants
      // of these names — everything else with a banned basename is a real
      // toolchain that must not ship.
      const shimPaths = new Set(ALL_SHIMS.map((n) => join(rootfsDir, "usr", "local", "bin", n)));
      const found: string[] = [];
      const walk = (dir: string): void => {
        for (const e of readdirSync(dir, { withFileTypes: true })) {
          const p = join(dir, e.name);
          if (e.isDirectory()) walk(p);
          else if (e.isFile() && banned.has(e.name) && !shimPaths.has(p)) found.push(p);
        }
      };
      walk(rootfsDir);
      expect(
        found,
        `real toolchain binaries inside ${sourceName} (only the PATH shims may carry these names)`,
      ).toEqual([]);
    }, 120_000);

    it("(9b) all 13 shims present in usr/local/bin; every unconditional shim prints REFUSAL_MESSAGE and exits 126; ovid exists", () => {
      for (const name of ALL_SHIMS) {
        expect(existsSync(join(rootfsDir, "usr", "local", "bin", name)), `${name} missing`).toBe(
          true,
        );
      }
      // The brief's explicit check (the roster above already implies it).
      expect(existsSync(join(rootfsDir, "usr", "local", "bin", "ovid"))).toBe(true);
      for (const name of UNCONDITIONAL_SHIMS) {
        // Portable execution: the host's `sh` interprets the shim directly.
        const r = spawnSync("sh", [join(rootfsDir, "usr", "local", "bin", name)], {
          encoding: "utf8",
          timeout: 10_000,
        });
        expect(r.status, `${name} must exit 126`).toBe(126);
        expect(r.stdout, `${name} stdout`).toBe(`${REFUSAL_MESSAGE}\n`);
        expect(r.stderr, `${name} stderr`).toBe("");
      }
    }, 120_000);
  },
);

// ---------------------------------------------------------------------------
// guarantee 10 — refusal copy parity (portable, grep-style file reads)
// ---------------------------------------------------------------------------

describe("isolation acceptance — refusal copy parity (portable)", () => {
  /**
   * Every file that carries the refusal sentence. `ovid` is the package
   * dispatcher (it legitimately prints no refusal); every other shim is a
   * blocking shim and MUST carry the exact copy.
   */
  function parityFiles(): Array<[string, string]> {
    const files: Array<[string, string]> = [["policy.ts", readFileSync(POLICY_TS, "utf8")]];
    for (const name of readdirSync(SHIMS_SRC_DIR)) {
      files.push([`shims/${name}`, readFileSync(join(SHIMS_SRC_DIR, name), "utf8")]);
    }
    files.push(["apps/worker/src/tools/systemPrompt.ts", readFileSync(WORKER_SYSTEM_PROMPT_TS, "utf8")]);
    return files;
  }

  it("(10a) REFUSAL_MESSAGE is byte-identical in policy.ts and every blocking shim — no divergent copy anywhere", () => {
    for (const [name, content] of parityFiles()) {
      // Any sentence that STARTS like the refusal copy must BE the refusal
      // copy — a divergent paraphrase fails loudly here.
      for (const m of content.matchAll(/Heavy native compilation[^\n"']*/g)) {
        expect(m[0], `${name} carries a divergent refusal copy`).toBe(REFUSAL_MESSAGE);
      }
    }
    // policy.ts is the definition (trivially contains it — pinned anyway).
    expect(readFileSync(POLICY_TS, "utf8")).toContain(REFUSAL_MESSAGE);
    // Every BLOCKING shim (all but `ovid`) carries the copy verbatim.
    for (const name of readdirSync(SHIMS_SRC_DIR)) {
      if (name === "ovid") continue;
      expect(
        readFileSync(join(SHIMS_SRC_DIR, name), "utf8"),
        `shim ${name} must carry REFUSAL_MESSAGE verbatim`,
      ).toContain(REFUSAL_MESSAGE);
    }
  });

  it("(10b) SYSTEM_PROMPT_V1's refusal notice quotes the single source (REFUSAL_MESSAGE import + the Tooling constraint line)", () => {
    const sp = readFileSync(WORKER_SYSTEM_PROMPT_TS, "utf8");
    // Task 12 wired the notice through the symbol, not a copy — pin BOTH the
    // import and the usage so the prompt can never drift or get re-hardcoded
    // silently (a hardcoded sentence would still be caught by 10a's scan).
    expect(sp).toMatch(/import\s*\{[^}]*REFUSAL_MESSAGE[^}]*\}\s*from\s*"@ovid\/sandbox"/);
    expect(sp).toContain("Tooling constraint: ${REFUSAL_MESSAGE}");
  });
});
