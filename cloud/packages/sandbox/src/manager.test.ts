import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough, type Writable } from "node:stream";
import { afterAll, describe, expect, it } from "vitest";
import { createCgroupManager, type CgroupManager } from "./cgroups.js";
import { loadSandboxConfig, type SandboxConfig } from "./config.js";
import {
  createSandboxManager,
  SandboxAdmissionError,
  SandboxCapacityError,
  type SandboxHandle,
  type SandboxManager,
} from "./manager.js";
import type { ChildProcessLike, JailLauncher } from "./launcher.js";
import { workspaceProjectId, type QuotaBackend } from "./quota.js";
import type { RootfsManifest } from "./rootfs.js";

/**
 * Portable SandboxManager tests (Task 8 Step 1): tmpdir workspacesRoot +
 * tmpdir cgroupRoot (inert files), a recording stub quota backend, a stub
 * allocator (200001+), an injected diskUsage, and a stub launcher. No bwrap,
 * no real cgroupfs, no host dependency — the real-jail proofs live in
 * manager.host.test.ts.
 *
 * The G1 seam (workspaceDir(userId, sessionId) — ruling P6-Q2, the P6
 * BrowserToolsDeps.workspaceDir surface) is pinned in its own describe: exact
 * path shape under the per-user uid tree, no env/cgroup/slot side effects,
 * per-user (not session-scoped) quota semantics.
 */

const roots: string[] = [];
afterAll(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

const FAKE_MANIFEST: RootfsManifest = {
  name: "test-rootfs",
  baseImage: "ubuntu:noble",
  baseImageDigest: `sha256:${"a".repeat(64)}`,
  nodeVersion: "v22.0.0",
  pnpmVersion: "9.0.0",
  uvVersion: "0.5.0",
  aptPackages: [],
  buildDate: "2026-10-16T00:00:00Z",
  builderCommit: "testcommit",
};

class RecordingQuota implements QuotaBackend {
  readonly kind = "noop" as const;
  readonly calls: Array<[path: string, projectId: number, hardBytes: number]> = [];
  async applyQuota(path: string, projectId: number, hardBytes: number): Promise<void> {
    this.calls.push([path, projectId, hardBytes]);
  }
}

interface StubScript {
  stdout?: string[];
  exitCode?: number;
}

class StubChild implements ChildProcessLike {
  readonly pid = 4242;
  // PassThrough (not just Readable) because the stub writes to the pipes
  // directly; PassThrough still satisfies ChildProcessLike's Readable fields.
  readonly stdout: PassThrough;
  readonly stderr: PassThrough;
  readonly stdin: Writable;
  private readonly emitter = new EventEmitter();

  constructor(private readonly script: StubScript) {
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.stdin = new PassThrough();
    queueMicrotask(() => {
      for (const chunk of script.stdout ?? []) this.stdout.write(chunk);
      this.emitter.emit("exit", script.exitCode ?? 0, null);
    });
  }

  kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
    this.emitter.emit("exit", null, signal);
    return true;
  }

  once(event: "exit", listener: (code: number | null, signal: NodeJS.Signals | null) => void): void;
  once(event: "error", listener: (err: Error) => void): void;
  // The union implementation signature is compatible with both precise
  // overloads (an `unknown[]`/`never[]` rest parameter is not), so no cast is
  // needed at the EventEmitter seam.
  once(
    event: "exit" | "error",
    listener:
      | ((code: number | null, signal: NodeJS.Signals | null) => void)
      | ((err: Error) => void),
  ): void {
    this.emitter.once(event, listener);
  }
}

class StubLauncher implements JailLauncher {
  readonly spawns: Array<{ bwrapArgv: string[]; opts: { uid: number; cgroupProcsFile: string } }> = [];
  nextScript: StubScript = {};

  spawn(
    bwrapArgv: string[],
    opts: { uid: number; gid: number; cgroupProcsFile: string; cwd: string },
  ): ChildProcessLike {
    const child = new StubChild(this.nextScript);
    this.spawns.push({ bwrapArgv, opts });
    return child;
  }

  spawnPty(): never {
    throw new Error("spawnPty is not part of the portable suite (Task 9)");
  }
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

interface FixtureOpts {
  config?: Partial<SandboxConfig>;
  allocateUid?(userId: string): Promise<number>;
  diskUsage?(): Promise<{ freeGb: number; warmGb: number }>;
}

interface Fixture {
  manager: SandboxManager;
  config: SandboxConfig;
  cgroups: CgroupManager;
  quota: RecordingQuota;
  launcher: StubLauncher;
  wsRoot: string;
  cgRoot: string;
  allocateCalls: string[];
}

async function freshFixture(opts: FixtureOpts = {}): Promise<Fixture> {
  const wsRoot = mkdtempSync(join(tmpdir(), "ovid-mgr-ws-"));
  const cgRoot = mkdtempSync(join(tmpdir(), "ovid-mgr-cg-"));
  roots.push(wsRoot, cgRoot);
  const config: SandboxConfig = {
    ...loadSandboxConfig({}),
    workspacesRoot: wsRoot,
    cgroupRoot: cgRoot,
    cgroupBase: "base",
    ...opts.config,
  };
  const cgroups = createCgroupManager(config);
  const quota = new RecordingQuota();
  const launcher = new StubLauncher();
  const allocateCalls: string[] = [];
  let next = 200_000;
  const allocateUid =
    opts.allocateUid ??
    (async (userId: string) => {
      allocateCalls.push(userId);
      return ++next;
    });
  const manager = createSandboxManager({
    config,
    allocateUid,
    cgroups,
    quota,
    launcher,
    rootfs: { path: "/tmp/ovid-mgr-rootfs-unused", manifest: FAKE_MANIFEST },
    diskUsage: opts.diskUsage ?? (async () => ({ freeGb: 100, warmGb: 0 })),
    clock: () => new Date("2026-10-16T00:00:00Z"),
  });
  return { manager, config, cgroups, quota, launcher, wsRoot, cgRoot, allocateCalls };
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------

/**
 * attach() chowns the per-user tree to the sandbox uid — a root-only
 * operation, exactly as in production (the worker runs as root). On an
 * unprivileged CI runner every attach returns EPERM, so these blocks run only
 * where they can exercise the real thing; acceptance.sh (root) covers them on
 * every gate run.
 */
const isRoot = typeof process.getuid === "function" && process.getuid() === 0;

describe.skipIf(!isRoot)("attach — creation layout", () => {
  it("creates the exact five-subdir layout, etc files with config dns, env cgroup caps, handle paths", async () => {
    const fx = await freshFixture();
    const h = await fx.manager.attach("u1");
    expect(h.uid).toBe(200001);
    const userRoot = join(fx.wsRoot, "200001");
    // The five subdirs (the .cache subtree lives under .home — Task 10 pins
    // host paths {uid}/.home/.cache/{pnpm-store,uv}, matching the jail's
    // /root/.cache binds of BASE_JAIL_ENV).
    for (const d of ["workspace", ".home", ".home/.cache/pnpm-store", ".home/.cache/uv", "etc"]) {
      expect(existsSync(join(userRoot, d)), `missing ${d}`).toBe(true);
    }
    // etc bundle: five files, resolv.conf from config.dns.
    for (const f of ["passwd", "group", "hosts", "resolv.conf", "nsswitch.conf"]) {
      expect(existsSync(join(userRoot, "etc", f)), `missing etc/${f}`).toBe(true);
    }
    expect(readFileSync(join(userRoot, "etc", "resolv.conf"), "utf8")).toBe(
      "nameserver 1.1.1.1\nnameserver 9.9.9.9\n",
    );
    // home dotfiles.
    expect(readFileSync(join(userRoot, ".home", ".npmrc"), "utf8")).toContain(
      "store-dir=/root/.cache/pnpm-store",
    );
    // env cgroup files hold the EXACT cap values from config.limits.
    const env = fx.cgroups.envPath(200001);
    expect(readFileSync(join(env, "cpu.max"), "utf8")).toBe("100000 100000");
    expect(readFileSync(join(env, "memory.max"), "utf8")).toBe("536870912");
    expect(readFileSync(join(env, "memory.swap.max"), "utf8")).toBe("0");
    expect(readFileSync(join(env, "pids.max"), "utf8")).toBe("64");
    // handle path shapes.
    expect(h.workspaceDir).toBe(join(userRoot, "workspace"));
    expect(h.homeDir).toBe(join(userRoot, ".home"));
    expect(h.jailWorkspaceDir).toBe("/workspace");
    // list()/activeCount reflect the live env.
    expect(fx.manager.list()).toEqual([
      { userId: "u1", uid: 200001, createdAt: "2026-10-16T00:00:00.000Z" },
    ]);
    expect(fx.manager.activeCount()).toBe(1);
    expect(fx.manager.get("u1")).toBe(h);
  });

  it("second attach returns the SAME handle and allocateUid is called once", async () => {
    const fx = await freshFixture();
    const h1 = await fx.manager.attach("u1");
    const h2 = await fx.manager.attach("u1");
    expect(h2).toBe(h1);
    expect(fx.allocateCalls).toEqual(["u1"]);
    expect(fx.manager.activeCount()).toBe(1);
  });

  it("concurrent attach for the same userId dedupes to one create", async () => {
    const fx = await freshFixture();
    const [a, b] = await Promise.all([fx.manager.attach("u1"), fx.manager.attach("u1")]);
    expect(a).toBe(b);
    expect(fx.allocateCalls).toEqual(["u1"]);
    expect(fx.manager.activeCount()).toBe(1);
  });

  it("handle.exec runs through a context wired to this uid and workspace", async () => {
    const fx = await freshFixture();
    fx.launcher.nextScript = { stdout: ["hi\n"], exitCode: 0 };
    const h = await fx.manager.attach("u1");
    const res = await h.exec({ command: "echo hi" });
    expect(res.exitCode).toBe(0);
    expect(res.stdout).toBe("hi\n");
    expect(fx.launcher.spawns).toHaveLength(1);
    const [rec] = fx.launcher.spawns;
    expect(rec.opts.uid).toBe(200001);
    // the workspace HOST path is bound at /workspace in the bwrap argv
    const i = rec.bwrapArgv.indexOf(h.workspaceDir);
    expect(i).toBeGreaterThan(0);
    expect(rec.bwrapArgv[i - 1]).toBe("--bind");
    expect(rec.bwrapArgv[i + 1]).toBe("/workspace");
  });
});

describe.skipIf(!isRoot)("destroy", () => {
  it("removes the env cgroup, deregisters, releases the slot — workspace DATA persists", async () => {
    const fx = await freshFixture();
    const h = await fx.manager.attach("u1");
    writeFileSync(join(h.workspaceDir, "keep.txt"), "data");
    await fx.manager.destroy("u1");
    expect(existsSync(fx.cgroups.envPath(200001))).toBe(false);
    expect(fx.manager.activeCount()).toBe(0);
    expect(fx.manager.list()).toEqual([]);
    expect(fx.manager.get("u1")).toBeUndefined();
    expect(readFileSync(join(fx.wsRoot, "200001", "workspace", "keep.txt"), "utf8")).toBe("data");
  });

  it("destroy of an unknown user is a no-op", async () => {
    const fx = await freshFixture();
    await expect(fx.manager.destroy("nobody")).resolves.toBeUndefined();
    expect(fx.manager.activeCount()).toBe(0);
  });

  it("handle.destroy() is the same path as manager.destroy()", async () => {
    const fx = await freshFixture();
    const h = await fx.manager.attach("u1");
    await h.destroy();
    expect(existsSync(fx.cgroups.envPath(200001))).toBe(false);
    expect(fx.manager.activeCount()).toBe(0);
  });
});

describe.skipIf(!isRoot)("admission — FIFO queue beyond maxActiveSandboxes", () => {
  it("two waiters resolve in enqueue order as slots free (FIFO)", async () => {
    const fx = await freshFixture({ config: { maxActiveSandboxes: 2, acquireTimeoutMs: 5_000 } });
    const h1 = await fx.manager.attach("u1");
    const h2 = await fx.manager.attach("u2");
    const order: string[] = [];
    const p3 = fx.manager.attach("u3").then((h) => {
      order.push(h.userId);
      return h;
    });
    const p4 = fx.manager.attach("u4").then((h) => {
      order.push(h.userId);
      return h;
    });
    await sleep(20); // both waiters are parked in the queue now
    expect(order).toEqual([]);
    expect(fx.manager.activeCount()).toBe(2);

    await h1.destroy();
    await p3; // the first waiter resolves; the second is still waiting
    expect(order).toEqual(["u3"]);
    expect(fx.manager.activeCount()).toBe(2); // u2 + u3

    await h2.destroy();
    await p4;
    expect(order).toEqual(["u3", "u4"]);
    expect(fx.manager.activeCount()).toBe(2); // u3 + u4
  });

  it("rejects with SandboxAdmissionError after acquireTimeoutMs", async () => {
    const fx = await freshFixture({ config: { maxActiveSandboxes: 1, acquireTimeoutMs: 50 } });
    const h1 = await fx.manager.attach("u1");
    await expect(fx.manager.attach("u2")).rejects.toBeInstanceOf(SandboxAdmissionError);
    expect(fx.manager.get("u1")).toBe(h1);
    expect(fx.manager.activeCount()).toBe(1);
    // the queue is not poisoned: after the holder releases, a new attach works
    await h1.destroy();
    const again = await fx.manager.attach("u2");
    expect(again.userId).toBe("u2");
    expect(fx.manager.activeCount()).toBe(1);
  });
});

describe.skipIf(!isRoot)("disk guard", () => {
  it("freeGb < minFreeGb ⇒ SandboxCapacityError(disk_pressure), slot released", async () => {
    const disk = { freeGb: 100, warmGb: 0 };
    const fx = await freshFixture({ diskUsage: async () => ({ ...disk }) });
    disk.freeGb = 1; // below the fixed minFreeGb of 2
    await expect(fx.manager.attach("u1")).rejects.toMatchObject({
      name: "SandboxCapacityError",
      reason: "disk_pressure",
    });
    expect(fx.manager.activeCount()).toBe(0); // the slot was released
    disk.freeGb = 100;
    const h = await fx.manager.attach("u1");
    expect(h.userId).toBe("u1");
    expect(fx.manager.activeCount()).toBe(1);
  });

  it("warmGb >= maxWarmGb ⇒ the same SandboxCapacityError", async () => {
    const fx = await freshFixture({
      config: { maxWarmGb: 8 },
      diskUsage: async () => ({ freeGb: 100, warmGb: 8 }),
    });
    await expect(fx.manager.attach("u1")).rejects.toBeInstanceOf(SandboxCapacityError);
    await expect(fx.manager.attach("u1")).rejects.toMatchObject({ reason: "disk_pressure" });
    expect(fx.manager.activeCount()).toBe(0);
  });
});

describe.skipIf(!isRoot)("quota recordings (byte math pinned)", () => {
  it("tier free: workspace 500×2^20 with workspaceProjectId, cache 2048×2^20 with cacheProjectId", async () => {
    const fx = await freshFixture();
    await fx.manager.attach("u1", { tier: "free" });
    const ws = join(fx.wsRoot, "200001", "workspace");
    const cache = join(fx.wsRoot, "200001", ".home", ".cache");
    expect(fx.quota.calls).toEqual([
      [ws, 200001, 524_288_000],
      [cache, 300001, 2_147_483_648],
    ]);
  });

  it("tier pro: workspace 2048×2^20", async () => {
    const fx = await freshFixture();
    await fx.manager.attach("u1", { tier: "pro" });
    const ws = join(fx.wsRoot, "200001", "workspace");
    const cache = join(fx.wsRoot, "200001", ".home", ".cache");
    expect(fx.quota.calls[0]).toEqual([ws, 200001, 2_147_483_648]);
    expect(fx.quota.calls[1]).toEqual([cache, 300001, 2_147_483_648]);
  });
});

describe.skipIf(!isRoot)("recovery", () => {
  it("cold envs stay cold, orphan cgroups are removed, re-warm preserves data", async () => {
    const fx = await freshFixture({
      allocateUid: async (u) => (u === "u5" ? 200_005 : 200_099),
    });
    // A cold env: workspace data on disk, no attached handle.
    mkdirSync(join(fx.wsRoot, "200005", "workspace"), { recursive: true });
    writeFileSync(join(fx.wsRoot, "200005", "workspace", "keep.txt"), "precious");
    // An env cgroup that HAS a workspace (crash leftover) — kept for re-warm.
    mkdirSync(fx.cgroups.envPath(200005), { recursive: true });
    // An ORPHAN env cgroup with NO workspace — must be killed + removed.
    mkdirSync(fx.cgroups.envPath(209999), { recursive: true });

    await fx.manager.recover();
    expect(fx.manager.list()).toEqual([]); // cold envs are not active
    expect(fx.manager.activeCount()).toBe(0);
    expect(existsSync(fx.cgroups.envPath(209999))).toBe(false);
    expect(existsSync(fx.cgroups.envPath(200005))).toBe(true); // data-backed, left alone

    // Re-warm: attach for the user mapped to 200005 — data intact, env live.
    const h = await fx.manager.attach("u5");
    expect(h.uid).toBe(200005);
    expect(h.workspaceDir).toBe(join(fx.wsRoot, "200005", "workspace"));
    expect(readFileSync(join(fx.wsRoot, "200005", "workspace", "keep.txt"), "utf8")).toBe(
      "precious",
    );
    expect(existsSync(fx.cgroups.envPath(200005))).toBe(true);
    expect(fx.manager.activeCount()).toBe(1);
  });
});

describe.skipIf(!isRoot)("workspaceDir(userId, sessionId) — the G1 / P6-Q2 seam", () => {
  it("returns {root}/{uid}/sessions/{sess} with the dir created — no env cgroup, no slot", async () => {
    const fx = await freshFixture();
    const before = fx.manager.activeCount();
    const p = await fx.manager.workspaceDir("u1", "sess-1");
    expect(p).toBe(join(fx.wsRoot, "200001", "sessions", "sess-1"));
    expect(existsSync(p)).toBe(true);
    // provisioning is NOT an attach: no env cgroup, no cgroup tree at all,
    // activeCount unchanged.
    expect(existsSync(fx.cgroups.envPath(200001))).toBe(false);
    expect(existsSync(join(fx.cgRoot, "base"))).toBe(false);
    expect(fx.manager.activeCount()).toBe(before);
    expect(fx.manager.list()).toEqual([]);
  });

  it("same (userId, sessionId) twice → same path, dir still there", async () => {
    const fx = await freshFixture();
    const p1 = await fx.manager.workspaceDir("u1", "sess-1");
    const p2 = await fx.manager.workspaceDir("u1", "sess-1");
    expect(p2).toBe(p1);
    expect(existsSync(p1)).toBe(true);
  });

  it("two sessionIds → sibling dirs", async () => {
    const fx = await freshFixture();
    const p1 = await fx.manager.workspaceDir("u1", "sess-1");
    const p2 = await fx.manager.workspaceDir("u1", "sess-2");
    expect(p1).not.toBe(p2);
    expect(existsSync(p1)).toBe(true);
    expect(existsSync(p2)).toBe(true);
    expect(join(p1, "..")).toBe(join(p2, ".."));
  });

  it("applies the per-user workspace quota project id — no session-scoped quota", async () => {
    const fx = await freshFixture();
    const p = await fx.manager.workspaceDir("u1", "sess-1");
    expect(fx.quota.calls).toEqual([[p, workspaceProjectId(200001), 524_288_000]]);
  });

  it("an attached sandbox's uid is reused without calling allocateUid again", async () => {
    const fx = await freshFixture();
    const h = await fx.manager.attach("u2"); // uid 200001 (first allocation)
    const callsBefore = fx.allocateCalls.length;
    const p = await fx.manager.workspaceDir("u2", "s");
    expect(p).toBe(join(fx.wsRoot, String(h.uid), "sessions", "s"));
    expect(existsSync(p)).toBe(true);
    expect(fx.allocateCalls.length).toBe(callsBefore);
  });
});

describe.skipIf(!isRoot)("workspaceDir quota tier — Task 8 review F1 carry", () => {
  it("a pro attach is never downgraded by a later workspaceDir call", async () => {
    const fx = await freshFixture();
    await fx.manager.attach("u1", { tier: "pro" });
    await fx.manager.workspaceDir("u1", "sess-1");
    // The seam re-asserts the PROJECT limit on the same XFS project as the
    // workspace; the last recorded bytes for that project must stay the PRO
    // limit (2048×2^20), NOT the free-tier 500×2^20 that silently capped the
    // user's live quota before this fix.
    const wsCalls = fx.quota.calls.filter(([, pid]) => pid === workspaceProjectId(200001));
    expect(wsCalls.length).toBeGreaterThanOrEqual(2);
    const last = wsCalls[wsCalls.length - 1];
    expect(last[2]).toBe(2_147_483_648);
  });

  it("the recorded tier survives destroy — a cold env's project is not downgraded either", async () => {
    const fx = await freshFixture();
    const h = await fx.manager.attach("u1", { tier: "pro" });
    await h.destroy();
    await fx.manager.workspaceDir("u1", "sess-1");
    const wsCalls = fx.quota.calls.filter(([, pid]) => pid === workspaceProjectId(200001));
    expect(wsCalls[wsCalls.length - 1][2]).toBe(2_147_483_648);
  });
});

describe.skipIf(!isRoot)("close()", () => {
  it("destroys every attached sandbox", async () => {
    const fx = await freshFixture();
    await fx.manager.attach("u1");
    await fx.manager.attach("u2");
    await fx.manager.close();
    expect(fx.manager.activeCount()).toBe(0);
    expect(fx.manager.list()).toEqual([]);
    expect(existsSync(fx.cgroups.envPath(200001))).toBe(false);
    expect(existsSync(fx.cgroups.envPath(200002))).toBe(false);
  });
});
