import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { createCgroupManager, type CgroupManager } from "./cgroups.js";
import { DEFAULT_SANDBOX_LIMITS } from "./config.js";

// Production-shaped multi-segment base — init() must create it recursively.
const CGROUP_BASE = "ovid-sandboxes.slice/ovid-worker.service";
const CONTROLLERS = "+cpu +memory +pids";

const roots: string[] = [];
afterAll(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

function freshManager(): { mgr: CgroupManager; base: string } {
  const root = mkdtempSync(join(tmpdir(), "ovid-cg-test-"));
  roots.push(root);
  const mgr = createCgroupManager({ cgroupRoot: root, cgroupBase: CGROUP_BASE });
  return { mgr, base: join(root, CGROUP_BASE) };
}

async function initializedManager(): Promise<{ mgr: CgroupManager; base: string }> {
  const ctx = freshManager();
  await ctx.mgr.init();
  return ctx;
}

describe("createCgroupManager path helpers", () => {
  it("envPath/leafPath shape: {root}/{base}/sandbox-{uid}[/{name}]", () => {
    const { mgr, base } = freshManager();
    expect(mgr.envPath(200001)).toBe(join(base, "sandbox-200001"));
    expect(mgr.leafPath(200001, "exec-1")).toBe(join(base, "sandbox-200001", "exec-1"));
    expect(mgr.leafPath(200001, "pty-7")).toBe(join(base, "sandbox-200001", "pty-7"));
  });

  it("procsFile(path) is {path}/cgroup.procs", () => {
    const { mgr } = freshManager();
    expect(mgr.procsFile("/sys/fs/cgroup/x/y")).toBe("/sys/fs/cgroup/x/y/cgroup.procs");
  });
});

describe("init()", () => {
  it("bootstraps leaf-first: worker leaf, own pid moved into it, controllers on base", async () => {
    const { mgr, base } = freshManager();
    await mgr.init();
    expect(existsSync(join(base, "worker"))).toBe(true);
    expect(readFileSync(join(base, "cgroup.subtree_control"), "utf8")).toBe(CONTROLLERS);
    expect(readFileSync(join(base, "worker", "cgroup.procs"), "utf8")).toBe(
      String(process.pid),
    );
  });

  it("is idempotent — a second init() leaves the state unchanged", async () => {
    const { mgr, base } = freshManager();
    await mgr.init();
    await mgr.init();
    expect(existsSync(join(base, "worker"))).toBe(true);
    expect(readFileSync(join(base, "cgroup.subtree_control"), "utf8")).toBe(CONTROLLERS);
    expect(readFileSync(join(base, "worker", "cgroup.procs"), "utf8")).toBe(
      String(process.pid),
    );
  });
});

describe("createEnv()", () => {
  it("writes the exact cap files for DEFAULT_SANDBOX_LIMITS", async () => {
    const { mgr, base } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    const env = join(base, "sandbox-200001");
    expect(existsSync(env)).toBe(true);
    expect(readFileSync(join(env, "memory.max"), "utf8")).toBe("536870912");
    expect(readFileSync(join(env, "memory.swap.max"), "utf8")).toBe("0");
    expect(readFileSync(join(env, "pids.max"), "utf8")).toBe("64");
    expect(readFileSync(join(env, "cpu.max"), "utf8")).toBe("100000 100000");
    expect(readFileSync(join(env, "cgroup.subtree_control"), "utf8")).toBe(CONTROLLERS);
  });

  it("writes exact values from the limits object, not defaults", async () => {
    const { mgr, base } = await initializedManager();
    await mgr.createEnv(200002, {
      cpuMax: "50000 100000",
      memoryMaxBytes: 67_108_864,
      memorySwapMaxBytes: 1_048_576,
      pidsMax: 16,
    });
    const env = join(base, "sandbox-200002");
    expect(readFileSync(join(env, "memory.max"), "utf8")).toBe("67108864");
    expect(readFileSync(join(env, "memory.swap.max"), "utf8")).toBe("1048576");
    expect(readFileSync(join(env, "pids.max"), "utf8")).toBe("16");
    expect(readFileSync(join(env, "cpu.max"), "utf8")).toBe("50000 100000");
  });
});

describe("createLeaf() / attachPid()", () => {
  it("creates …/sandbox-200001/exec-1 and returns the absolute path", async () => {
    const { mgr, base } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    const leaf = await mgr.createLeaf(200001, "exec-1");
    expect(leaf).toBe(join(base, "sandbox-200001", "exec-1"));
    expect(existsSync(leaf)).toBe(true);
  });

  it("attachPid writes the pid into {leaf}/cgroup.procs", async () => {
    const { mgr } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    const leaf = await mgr.createLeaf(200001, "exec-1");
    await mgr.attachPid(leaf, 4242);
    expect(readFileSync(join(leaf, "cgroup.procs"), "utf8")).toBe("4242");
  });
});

describe("kill()", () => {
  it("writes cgroup.kill, polls procs empty, and removes the cgroup", async () => {
    const { mgr } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    const leaf = await mgr.createLeaf(200001, "exec-1");
    await mgr.kill(leaf);
    expect(existsSync(leaf)).toBe(false);
  });

  it("signals cgroup.kill=1 before attempting removal", async () => {
    const { mgr } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    const leaf = await mgr.createLeaf(200001, "pty-1");
    // A stray subdirectory makes the final rmdir fail (ENOTEMPTY) so the
    // pre-rmdir state is observable: cgroup.kill must already hold "1".
    mkdirSync(join(leaf, "stray"));
    await expect(mgr.kill(leaf)).rejects.toThrow();
    expect(readFileSync(join(leaf, "cgroup.kill"), "utf8")).toBe("1");
  });
});

describe("remove() / readFile() / listChildren()", () => {
  it("remove rmdirs an empty cgroup", async () => {
    const { mgr } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    const leaf = await mgr.createLeaf(200001, "job-1");
    await mgr.remove(leaf);
    expect(existsSync(leaf)).toBe(false);
  });

  it("remove refuses a non-empty cgroup", async () => {
    const { mgr } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    await mgr.createLeaf(200001, "exec-1");
    await expect(mgr.remove(mgr.envPath(200001))).rejects.toThrow(/ENOTEMPTY/);
  });

  it("reads interface files (memory.events, cpu.stat, …)", async () => {
    const { mgr } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    expect(await mgr.readFile(mgr.envPath(200001), "memory.max")).toBe("536870912");
    expect(await mgr.readFile(mgr.envPath(200001), "cpu.max")).toBe("100000 100000");
  });

  it("lists child cgroup directories as absolute paths", async () => {
    const { mgr } = await initializedManager();
    await mgr.createEnv(200001, DEFAULT_SANDBOX_LIMITS);
    await mgr.createLeaf(200001, "exec-1");
    await mgr.createLeaf(200001, "pty-1");
    const env = mgr.envPath(200001);
    expect((await mgr.listChildren(env)).sort()).toEqual([
      join(env, "exec-1"),
      join(env, "pty-1"),
    ]);
  });
});
