import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough, type Writable } from "node:stream";
import { afterAll, describe, expect, it } from "vitest";
import { createCgroupManager, type CgroupManager } from "./cgroups.js";
import { DEFAULT_SANDBOX_LIMITS, loadSandboxConfig, type SandboxConfig } from "./config.js";
import { execOnce, makeJailContext } from "./exec.js";
import { createSetuidLauncher, type ChildProcessLike, type JailLauncher } from "./launcher.js";
import { REFUSAL_MESSAGE } from "./policy.js";

/**
 * Portable exec API tests (Task 7 Step 1): a stub JailLauncher that records
 * spawns and emits canned child behavior, plus a tmpdir-rooted CgroupManager
 * (inert files — no real cgroupfs, no bwrap, no host dependency).
 *
 * The blocked-path zero-side-effects contract (Review Focus #1: no leaf
 * created, no spawn) and the cgroup-procs-file ordering contract are pinned
 * here; the real-jail proofs live in exec.host.test.ts.
 */

const CGROUP_BASE = "ovid-sandboxes.slice/ovid-worker.service";
const TEST_UID = 200099;

const roots: string[] = [];
afterAll(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Stub launcher + stub children
// ---------------------------------------------------------------------------

/** What a stub child should do once spawned. */
interface StubScript {
  /** stdout chunks to emit (in order). */
  stdout?: string[];
  /** stderr chunks to emit (in order). */
  stderr?: string[];
  /** Exit code to report; default 0. */
  exitCode?: number;
  /** Never emit "exit" — even when killed (the timeout fixture). */
  neverExit?: boolean;
}

interface RecordedSpawn {
  bwrapArgv: string[];
  opts: {
    uid: number;
    gid: number;
    cgroupProcsFile: string;
    cwd: string;
    env?: NodeJS.ProcessEnv;
  };
  child: StubChild;
}

class StubChild implements ChildProcessLike {
  readonly pid = 4242;
  // PassThrough (not just Readable) because the stub writes to the pipes
  // directly; PassThrough still satisfies ChildProcessLike's Readable fields.
  readonly stdout: PassThrough;
  readonly stderr: PassThrough;
  readonly stdin: Writable;
  readonly kills: string[] = [];
  readonly stdinData: string[] = [];
  private readonly emitter = new EventEmitter();

  constructor(private readonly script: StubScript) {
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.stdin = new PassThrough();
    this.stdin.on("data", (d: Buffer) => this.stdinData.push(d.toString()));
    // Emit asynchronously so the exec collector attaches before data flows,
    // like real pipes.
    queueMicrotask(() => {
      for (const chunk of script.stdout ?? []) this.stdout.write(chunk);
      for (const chunk of script.stderr ?? []) this.stderr.write(chunk);
      if (!script.neverExit) this.emitter.emit("exit", script.exitCode ?? 0, null);
    });
  }

  kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
    this.kills.push(signal);
    if (!this.script.neverExit) this.emitter.emit("exit", null, signal);
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
  readonly spawns: RecordedSpawn[] = [];
  /** Script for the NEXT spawn (set by each test before calling execOnce). */
  nextScript: StubScript = {};

  spawn(
    bwrapArgv: string[],
    opts: {
      uid: number;
      gid: number;
      cgroupProcsFile: string;
      cwd: string;
      env?: NodeJS.ProcessEnv;
    },
  ): ChildProcessLike {
    const child = new StubChild(this.nextScript);
    this.spawns.push({ bwrapArgv, opts, child });
    return child;
  }

  spawnPty(): never {
    throw new Error("spawnPty is not part of the portable suite (Task 9)");
  }
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

interface Fixture {
  mgr: CgroupManager;
  stub: StubLauncher;
  envPath: string;
  run: (req: Parameters<typeof execOnce>[1]) => ReturnType<typeof execOnce>;
  ctxWorkspaceDir: string;
}

async function freshFixture(script: StubScript = {}): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), "ovid-exec-test-"));
  roots.push(root);
  const cfg: SandboxConfig = {
    ...loadSandboxConfig({}),
    cgroupRoot: root,
    cgroupBase: CGROUP_BASE,
    launch: "setuid",
  };
  const mgr = createCgroupManager({ cgroupRoot: root, cgroupBase: CGROUP_BASE });
  const stub = new StubLauncher();
  stub.nextScript = script;
  const workspaceDir = join(root, "ws");
  const ctx = makeJailContext({
    config: cfg,
    cgroups: mgr,
    launcher: stub,
    uid: TEST_UID,
    rootfs: "/tmp/ovid-rootfs-unused",
    workspaceDir,
    homeDir: join(root, "home"),
    etcDir: join(root, "etc"),
  });
  // execOnce assumes the env cgroup already exists (Task 8 manager owns it).
  await mgr.createEnv(TEST_UID, DEFAULT_SANDBOX_LIMITS);
  return {
    mgr,
    stub,
    envPath: mgr.envPath(TEST_UID),
    run: (req) => execOnce(ctx, req),
    ctxWorkspaceDir: workspaceDir,
  };
}

// ---------------------------------------------------------------------------

describe("execOnce — happy path", () => {
  it("collects stdout and the exit code from the stub child", async () => {
    const fx = await freshFixture({ stdout: ["hi\n"], exitCode: 0 });
    const res = await fx.run({ command: "echo hi" });
    expect(res).toEqual({
      exitCode: 0,
      stdout: "hi\n",
      stderr: "",
      timedOut: false,
      truncated: false,
      blocked: false,
      refusal: null,
    });
  });

  it("spawns exactly once, with payload [bash,-c,command] behind the bwrap argv", async () => {
    const fx = await freshFixture({ stdout: ["ok"], exitCode: 0 });
    await fx.run({ command: "echo hi" });
    expect(fx.stub.spawns).toHaveLength(1);
    const [rec] = fx.stub.spawns;
    // bwrap binary leads, and the golden argv ends with the payload.
    expect(rec.bwrapArgv[0]).toBe(loadSandboxConfig({}).bwrapPath);
    expect(rec.bwrapArgv.slice(-3)).toEqual(["/bin/bash", "-c", "echo hi"]);
    expect(rec.opts.uid).toBe(TEST_UID);
    expect(rec.opts.gid).toBe(TEST_UID);
    expect(rec.opts.cwd).toBe(fx.ctxWorkspaceDir);
  });

  it("writes and ends stdin when the request carries one", async () => {
    const fx = await freshFixture({ exitCode: 0 });
    await fx.run({ command: "cat", stdin: "hello\n" });
    const [rec] = fx.stub.spawns;
    expect(rec.child.stdinData).toEqual(["hello\n"]);
    expect((rec.child.stdin as PassThrough).writableEnded).toBe(true);
  });

  it("swallows an async stdin error instead of crashing (I-2)", async () => {
    // A stdin that errors on write — the shape of EPIPE from a child that
    // exits without reading. execOnce attaches a no-op 'error' handler, so
    // this must resolve normally, not become an uncaught exception.
    const root = mkdtempSync(join(tmpdir(), "ovid-exec-test-"));
    roots.push(root);
    const mgr = createCgroupManager({ cgroupRoot: root, cgroupBase: CGROUP_BASE });
    await mgr.createEnv(TEST_UID, DEFAULT_SANDBOX_LIMITS);
    const hostileStdin = new PassThrough();
    const launcher: JailLauncher = {
      spawn(): ChildProcessLike {
        const child = new StubChild({ exitCode: 0 });
        Object.defineProperty(child, "stdin", { value: hostileStdin });
        hostileStdin.on("data", () => hostileStdin.emit("error", new Error("EPIPE")));
        return child;
      },
      spawnPty(): never {
        throw new Error("no pty");
      },
    };
    const ctx = makeJailContext({
      config: loadSandboxConfig({}),
      cgroups: mgr,
      launcher,
      uid: TEST_UID,
      rootfs: "/tmp/x",
      workspaceDir: "/tmp/ws",
      homeDir: "/tmp/home",
      etcDir: "/tmp/etc",
    });
    const res = await execOnce(ctx, { command: "cat", stdin: "bye\n" });
    expect(res.exitCode).toBe(0);
    expect(res.blocked).toBe(false);
  });
});

describe("execOnce — blocked commands (Review Focus #1: zero side effects)", () => {
  it("blocks 'gradle build' with the exact refusal, no spawn, no leaf", async () => {
    const fx = await freshFixture({ stdout: ["should never run"] });
    const res = await fx.run({ command: "gradle build" });
    expect(res).toEqual({
      exitCode: null,
      stdout: "",
      stderr: "",
      timedOut: false,
      truncated: false,
      blocked: true,
      refusal: REFUSAL_MESSAGE,
    });
    expect(fx.stub.spawns).toHaveLength(0);
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
  });

  it("blocks an argv request whose quoted join parses to a denied head", async () => {
    const fx = await freshFixture({});
    // shell-quote join: "bash -c make" — recursive -c descent must catch it.
    const res = await fx.run({ argv: ["bash", "-c", "make"] });
    expect(res.blocked).toBe(true);
    expect(res.refusal).toBe(REFUSAL_MESSAGE);
    expect(fx.stub.spawns).toHaveLength(0);
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
  });

  it("blocks a fork bomb given as argv", async () => {
    const fx = await freshFixture({});
    const res = await fx.run({ argv: ["bash", "-c", ":(){ :|:& };:"] });
    expect(res.blocked).toBe(true);
    expect(fx.stub.spawns).toHaveLength(0);
  });
});

describe("execOnce — argv normalization via shell-quote", () => {
  it("allows ['node','-e','x'] and spawns the ORIGINAL argv as the payload", async () => {
    const fx = await freshFixture({ stdout: ["x"], exitCode: 0 });
    const res = await fx.run({ argv: ["node", "-e", "x"] });
    expect(res.blocked).toBe(false);
    expect(res.exitCode).toBe(0);
    const [rec] = fx.stub.spawns;
    expect(rec.bwrapArgv.slice(-3)).toEqual(["node", "-e", "x"]);
  });

  it("quotes argv words so shell structure is preserved for the policy check", async () => {
    const fx = await freshFixture({ exitCode: 0 });
    // Quoted join: echo 'make; make' — ONE word, a literal argument to echo.
    // A naive space join ("echo make; make") would falsely block it.
    const res = await fx.run({ argv: ["echo", "make; make"] });
    expect(res.blocked).toBe(false);
    expect(fx.stub.spawns).toHaveLength(1);
    expect(fx.stub.spawns[0].bwrapArgv.slice(-2)).toEqual(["echo", "make; make"]);
  });
});

describe("execOnce — timeout", () => {
  it("kills the leaf and reports timedOut when the child never exits", async () => {
    const fx = await freshFixture({ neverExit: true });
    const res = await fx.run({ command: "sleep 300", timeoutMs: 50 });
    expect(res.timedOut).toBe(true);
    expect(res.exitCode).toBeNull();
    expect(res.blocked).toBe(false);
    // The stub child was signalled...
    expect(fx.stub.spawns[0].child.kills).toContain("SIGKILL");
    // ...and the leaf was killed (kill() removes it — Task 6 semantics).
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
  });
});

describe("execOnce — output cap", () => {
  it("caps stdout at maxOutputBytes, keeps draining, sets truncated", async () => {
    // 2 MB in 8 chunks; cap 1024.
    const chunk = "a".repeat(128 * 1024);
    const fx = await freshFixture({ stdout: Array(16).fill(chunk), exitCode: 0 });
    const res = await fx.run({ command: "cat big", maxOutputBytes: 1024 });
    expect(res.truncated).toBe(true);
    expect(res.stdout.length).toBeLessThanOrEqual(1024);
    expect(res.stdout).toBe("a".repeat(1024));
    expect(res.exitCode).toBe(0);
    // The exec resolved (child exit collected) despite discarded output —
    // i.e. the drain kept going rather than stalling the child.
    expect(fx.stub.spawns).toHaveLength(1);
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
  });

  it("does not set truncated when output fits the cap", async () => {
    const fx = await freshFixture({ stdout: ["small"], exitCode: 0 });
    const res = await fx.run({ command: "echo small" });
    expect(res.truncated).toBe(false);
    expect(res.stdout).toBe("small");
  });
});

describe("execOnce — cgroup leaf lifecycle", () => {
  it("passes cgroups.procsFile(leaf) to the launcher (ordering contract)", async () => {
    const fx = await freshFixture({ exitCode: 0 });
    await fx.run({ command: "true" });
    const leaves = await fx.mgr.listChildren(fx.envPath);
    // The leaf is removed on completion — the recorded procsFile is the
    // contract: {envPath}/{leaf}/cgroup.procs, under THIS env cgroup.
    const [rec] = fx.stub.spawns;
    expect(rec.opts.cgroupProcsFile.startsWith(fx.envPath)).toBe(true);
    expect(rec.opts.cgroupProcsFile.endsWith("/cgroup.procs")).toBe(true);
    const leafName = rec.opts.cgroupProcsFile.slice(
      fx.envPath.length + 1,
      -"/cgroup.procs".length,
    );
    expect(leafName).toMatch(/^exec-\d+-[a-f0-9]+$/);
    expect(rec.opts.cgroupProcsFile).toBe(fx.mgr.procsFile(fx.mgr.leafPath(TEST_UID, leafName)));
  });

  it("names leaves exec-{n}-{rand} with a per-context monotonic n", async () => {
    const fx = await freshFixture({ exitCode: 0 });
    await fx.run({ command: "true" });
    await fx.run({ command: "true" });
    const names = fx.stub.spawns.map((s) => {
      const p = s.opts.cgroupProcsFile;
      return p.slice(fx.envPath.length + 1, -"/cgroup.procs".length);
    });
    expect(names[0]).toMatch(/^exec-1-[a-f0-9]+$/);
    expect(names[1]).toMatch(/^exec-2-[a-f0-9]+$/);
    expect(names[0]).not.toBe(names[1]);
  });

  it("removes the leaf after a successful run (finally contract)", async () => {
    const fx = await freshFixture({ exitCode: 0 });
    await fx.run({ command: "true" });
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
  });

  it("removes the leaf when the spawn itself throws", async () => {
    const fx = await freshFixture({});
    const mgr = fx.mgr;
    const ctx = makeJailContext({
      config: loadSandboxConfig({}),
      cgroups: mgr,
      launcher: {
        spawn(): ChildProcessLike {
          throw new Error("launcher exploded");
        },
        spawnPty(): never {
          throw new Error("no pty");
        },
      },
      uid: TEST_UID,
      rootfs: "/tmp/x",
      workspaceDir: "/tmp/ws",
      homeDir: "/tmp/home",
      etcDir: "/tmp/etc",
    });
    await expect(execOnce(ctx, { command: "true" })).rejects.toThrow(/launcher exploded/);
    expect(await mgr.listChildren(mgr.envPath(TEST_UID))).toEqual([]);
  });
});

describe("execOnce — request validation", () => {
  it("rejects a request with both command and argv", async () => {
    const fx = await freshFixture({});
    await expect(fx.run({ command: "echo hi", argv: ["echo", "hi"] })).rejects.toThrow(
      /exactly one of command or argv/,
    );
  });

  it("rejects a request with neither command nor argv", async () => {
    const fx = await freshFixture({});
    await expect(fx.run({})).rejects.toThrow(/exactly one of command or argv/);
  });

  it("rejects an empty command / empty argv", async () => {
    const fx = await freshFixture({});
    await expect(fx.run({ command: "" })).rejects.toThrow(/non-empty/);
    await expect(fx.run({ argv: [] })).rejects.toThrow(/non-empty/);
  });
});

describe("createSetuidLauncher — scratch lifecycle", () => {
  it("does not leak the argv scratch dir when spawn prep throws synchronously (M-1)", () => {
    const before = new Set(readdirSync(tmpdir()).filter((e) => e.startsWith("ovid-enter-")));
    const launcher = createSetuidLauncher({ launcherPath: "/nonexistent/launcher" });
    // A Symbol in the argv makes the NUL join throw synchronously inside the
    // launcher — after the mkdtemp, before any child exists to clean up.
    // (A bad cwd only errors ASYNC via the child's 'error' event — verified —
    // so it is not a sync-throw vector.)
    expect(() =>
      launcher.spawn([Symbol("x") as unknown as string], {
        uid: TEST_UID,
        gid: TEST_UID,
        cgroupProcsFile: "/tmp/none/cgroup.procs",
        cwd: tmpdir(),
      }),
    ).toThrow();
    const after = readdirSync(tmpdir()).filter(
      (e) => e.startsWith("ovid-enter-") && !before.has(e),
    );
    expect(after).toEqual([]);
  });

  it("cleans the argv scratch dir on the async error path too", async () => {
    const before = new Set(readdirSync(tmpdir()).filter((e) => e.startsWith("ovid-enter-")));
    const launcher = createSetuidLauncher({ launcherPath: "/nonexistent/launcher" });
    const child = launcher.spawn(["/usr/bin/true"], {
      uid: TEST_UID,
      gid: TEST_UID,
      cgroupProcsFile: "/tmp/none/cgroup.procs",
      cwd: tmpdir(),
    });
    // bash exists, so the child spawns and the sync-throw path is NOT taken;
    // cleanup must instead ride the child's exit/error listeners.
    expect(child.pid).toBeGreaterThan(0);
    await new Promise<void>((resolve) => {
      child.once("exit", () => resolve());
      child.once("error", () => resolve());
    });
    // rmSync runs synchronously in the exit/error listener — a macrotask
    // suffices before the leftovers check.
    await new Promise<void>((resolve) => setImmediate(resolve));
    const after = readdirSync(tmpdir()).filter(
      (e) => e.startsWith("ovid-enter-") && !before.has(e),
    );
    expect(after).toEqual([]);
  });
});

describe("makeJailContext", () => {
  it("assembles the context verbatim", () => {
    const cfg = loadSandboxConfig({});
    const mgr = createCgroupManager({ cgroupRoot: "/tmp/x", cgroupBase: "b" });
    const stub = new StubLauncher();
    const ctx = makeJailContext({
      config: cfg,
      cgroups: mgr,
      launcher: stub,
      uid: 200123,
      rootfs: "/opt/ovid-rootfs/r1",
      workspaceDir: "/workspaces/users/200123/sessions/s1",
      homeDir: "/workspaces/users/200123/home",
      etcDir: "/workspaces/users/200123/etc",
    });
    expect(ctx.config).toBe(cfg);
    expect(ctx.cgroups).toBe(mgr);
    expect(ctx.launcher).toBe(stub);
    expect(ctx.uid).toBe(200123);
    expect(ctx.rootfs).toBe("/opt/ovid-rootfs/r1");
    expect(ctx.workspaceDir).toBe("/workspaces/users/200123/sessions/s1");
    expect(ctx.homeDir).toBe("/workspaces/users/200123/home");
    expect(ctx.etcDir).toBe("/workspaces/users/200123/etc");
    expect(existsSync("/tmp/x")).toBe(false); // pure assembly, no fs effects
  });
});
