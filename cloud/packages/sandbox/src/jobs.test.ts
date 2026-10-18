import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { PassThrough, type Writable } from "node:stream";
import { afterAll, describe, expect, it } from "vitest";
import { createCgroupManager, type CgroupManager } from "./cgroups.js";
import { DEFAULT_SANDBOX_LIMITS, loadSandboxConfig, type SandboxConfig } from "./config.js";
import { makeJailContext } from "./exec.js";
import {
  createJobRegistry,
  spawnLongRunning,
  type JobInfo,
  type JobOutput,
  type JobRegistry,
} from "./jobs.js";
import type { ChildProcessLike, JailLauncher, PtyChildLike } from "./launcher.js";
import {
  createSandboxManager,
  type SandboxHandle,
  type SandboxManager,
} from "./manager.js";
import { CommandBlockedError, REFUSAL_MESSAGE } from "./policy.js";
import { createNoopQuotaBackend } from "./quota.js";
import type { RootfsManifest } from "./rootfs.js";
import type { JailContext } from "./types.js";

/**
 * Portable JobRegistry + spawnLongRunning tests (Task 9 Step 1): a stub
 * JailLauncher whose children are PassThrough pipes (and stub pty children
 * for the handle wiring), plus tmpdir-rooted cgroups (inert files). The
 * cgroup tree-kill SEMANTICS are pinned host-side (pty.host.test.ts); here
 * we pin the orchestration: policy gate, leaf lifecycle, ring plumbing,
 * job_limit, and the P5 stdio-MCP backing (pipes, never a pty).
 */

const CGROUP_BASE = "ovid-sandboxes.slice/ovid-worker.service";
const TEST_UID = 200096;

const roots: string[] = [];
afterAll(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const tick = () => new Promise<void>((resolve) => setImmediate(resolve));

async function until(fn: () => boolean, ms = 5_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!fn() && Date.now() < deadline) await sleep(25);
}

function decode(chunks: { data: string }[]): string {
  return chunks.map((c) => Buffer.from(c.data, "base64").toString("utf8")).join("");
}

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

/** What a stub pipe child should do once spawned. */
interface StubScript {
  /** stdout chunks emitted right after spawn. */
  stdout?: string[];
  /** Exit with this code right after spawn; undefined → stay alive until killed. */
  exitCode?: number;
}

interface RecordedSpawn {
  bwrapArgv: string[];
  opts: { uid: number; gid: number; cgroupProcsFile: string; cwd: string };
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
    this.stdin.on("data", (d: Buffer) => this.stdinData.push(d.toString("utf8")));
    // Emit asynchronously so collectors attach before data flows, like real pipes.
    queueMicrotask(() => {
      for (const chunk of script.stdout ?? []) this.stdout.write(chunk);
      if (script.exitCode !== undefined) this.emitter.emit("exit", script.exitCode, null);
    });
  }

  kill(signal: NodeJS.Signals = "SIGTERM"): boolean {
    this.kills.push(signal);
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

/** Stub pty child for the handle-wiring tests (no real tty). */
class StubPtyChild implements PtyChildLike {
  readonly pid = 4343;
  readonly writes: string[] = [];
  readonly resizes: Array<[number, number]> = [];
  readonly kills: string[] = [];
  private dataListeners: Array<(d: string) => void> = [];
  private exitListeners: Array<(e: { exitCode: number; signal?: number }) => void> = [];

  constructor(
    readonly cols: number,
    readonly rows: number,
  ) {}

  write(data: string): void {
    this.writes.push(data);
  }

  kill(signal = "SIGTERM"): boolean {
    this.kills.push(signal);
    for (const l of this.exitListeners) l({ exitCode: 0, signal: 15 });
    return true;
  }

  resize(cols: number, rows: number): void {
    this.resizes.push([cols, rows]);
  }

  onData(listener: (data: string) => void): unknown {
    this.dataListeners.push(listener);
    return listener;
  }

  onExit(listener: (e: { exitCode: number; signal?: number }) => void): unknown {
    this.exitListeners.push(listener);
    return listener;
  }

  pause(): void {}
  resume(): void {}

  emitData(data: string): void {
    for (const l of this.dataListeners) l(data);
  }
}

class StubLauncher implements JailLauncher {
  readonly spawns: RecordedSpawn[] = [];
  readonly ptySpawns: Array<{ bwrapArgv: string[]; cols: number; rows: number }> = [];
  nextScript: StubScript = {};

  spawn(
    bwrapArgv: string[],
    opts: { uid: number; gid: number; cgroupProcsFile: string; cwd: string },
  ): ChildProcessLike {
    const child = new StubChild(this.nextScript);
    this.spawns.push({ bwrapArgv, opts, child });
    return child;
  }

  spawnPty(
    bwrapArgv: string[],
    opts: { cols: number; rows: number },
  ): PtyChildLike {
    const child = new StubPtyChild(opts.cols, opts.rows);
    this.ptySpawns.push({ bwrapArgv, cols: opts.cols, rows: opts.rows });
    return child;
  }
}

/** Delegating CgroupManager that records kill() order (the destroy contract). */
class KillRecorderCgroups implements CgroupManager {
  readonly killCalls: string[] = [];
  constructor(private readonly inner: CgroupManager) {}
  init(): Promise<void> {
    return this.inner.init();
  }
  envPath(uid: number): string {
    return this.inner.envPath(uid);
  }
  leafPath(uid: number, name: string): string {
    return this.inner.leafPath(uid, name);
  }
  createEnv(uid: number, limits: typeof DEFAULT_SANDBOX_LIMITS): Promise<void> {
    return this.inner.createEnv(uid, limits);
  }
  createLeaf(uid: number, name: string): Promise<string> {
    return this.inner.createLeaf(uid, name);
  }
  attachPid(path: string, pid: number): Promise<void> {
    return this.inner.attachPid(path, pid);
  }
  procsFile(path: string): string {
    return this.inner.procsFile(path);
  }
  kill(path: string): Promise<void> {
    this.killCalls.push(path);
    return this.inner.kill(path);
  }
  remove(path: string): Promise<void> {
    return this.inner.remove(path);
  }
  readFile(path: string, file: string): Promise<string> {
    return this.inner.readFile(path, file);
  }
  listChildren(path: string): Promise<string[]> {
    return this.inner.listChildren(path);
  }
}

// ---------------------------------------------------------------------------
// Fixtures
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

interface Fixture {
  mgr: CgroupManager;
  launcher: StubLauncher;
  ctx: JailContext;
  jobs: JobRegistry;
  envPath: string;
  run: (req: Parameters<typeof spawnLongRunning>[1]) => ReturnType<typeof spawnLongRunning>;
}

async function freshFixture(script: StubScript = {}): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), "ovid-jobs-test-"));
  roots.push(root);
  const cfg: SandboxConfig = {
    ...loadSandboxConfig({}),
    cgroupRoot: root,
    cgroupBase: CGROUP_BASE,
    launch: "setuid",
  };
  const mgr = createCgroupManager({ cgroupRoot: root, cgroupBase: CGROUP_BASE });
  const launcher = new StubLauncher();
  launcher.nextScript = script;
  const ctx = makeJailContext({
    config: cfg,
    cgroups: mgr,
    launcher,
    uid: TEST_UID,
    rootfs: "/tmp/ovid-rootfs-unused",
    workspaceDir: join(root, "ws"),
    homeDir: join(root, "home"),
    etcDir: join(root, "etc"),
  });
  await mgr.createEnv(TEST_UID, DEFAULT_SANDBOX_LIMITS);
  return {
    mgr,
    launcher,
    ctx,
    jobs: createJobRegistry(ctx),
    envPath: mgr.envPath(TEST_UID),
    run: (req) => spawnLongRunning(ctx, req),
  };
}

/** Manager-level fixture for the SandboxHandle wiring tests. */
interface ManagerFixture {
  manager: SandboxManager;
  handle: SandboxHandle;
  cgroups: KillRecorderCgroups;
  launcher: StubLauncher;
  envPath: string;
}

async function freshManagerFixture(): Promise<ManagerFixture> {
  const wsRoot = mkdtempSync(join(tmpdir(), "ovid-jobs-mgr-ws-"));
  const cgRoot = mkdtempSync(join(tmpdir(), "ovid-jobs-mgr-cg-"));
  roots.push(wsRoot, cgRoot);
  const config: SandboxConfig = {
    ...loadSandboxConfig({}),
    workspacesRoot: wsRoot,
    cgroupRoot: cgRoot,
    cgroupBase: "base",
  };
  const raw = createCgroupManager({ cgroupRoot: cgRoot, cgroupBase: "base" });
  const cgroups = new KillRecorderCgroups(raw);
  const launcher = new StubLauncher();
  const manager = createSandboxManager({
    config,
    allocateUid: async () => TEST_UID,
    cgroups,
    quota: createNoopQuotaBackend(),
    launcher,
    rootfs: { path: "/tmp/ovid-rootfs-unused", manifest: FAKE_MANIFEST },
    diskUsage: async () => ({ freeGb: 100, warmGb: 0 }),
    clock: () => new Date("2026-10-16T00:00:00Z"),
  });
  const handle = await manager.attach("u1");
  return { manager, handle, cgroups, launcher, envPath: cgroups.envPath(TEST_UID) };
}

/** The leaf directory of a recorded spawn ({cgroupProcsFile} minus /cgroup.procs). */
function leafOf(rec: { opts: { cgroupProcsFile: string } }): string {
  return dirname(rec.opts.cgroupProcsFile);
}

// ---------------------------------------------------------------------------
// JobRegistry
// ---------------------------------------------------------------------------

describe("JobRegistry — policy gate (zero side effects)", () => {
  it("start({command:'make'}) throws CommandBlockedError with REFUSAL_MESSAGE and spawns nothing", async () => {
    const fx = await freshFixture();
    const err: unknown = await fx.jobs.start({ command: "make" }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(CommandBlockedError);
    expect((err as CommandBlockedError).refusal).toBe(REFUSAL_MESSAGE);
    expect(fx.launcher.spawns).toHaveLength(0);
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
  });
});

describe("JobRegistry — lifecycle", () => {
  it("start({command:'sleep 5'}) → list()[0].state === 'running'", async () => {
    const fx = await freshFixture();
    const info = await fx.jobs.start({ command: "sleep 5" });
    expect(info.state).toBe("running");
    expect(info.exitCode).toBeNull();
    expect(info.command).toBe("sleep 5");
    expect(typeof info.startedAt).toBe("string");
    expect(fx.jobs.list().map((j) => j.state)).toEqual(["running"]);
    expect(fx.jobs.size).toBe(1);
    await fx.jobs.killAll();
  });

  it("payload is [bash,-c,command] behind the bwrap argv, under a job-* leaf", async () => {
    const fx = await freshFixture();
    await fx.jobs.start({ command: "echo hi" });
    const [rec] = fx.launcher.spawns;
    expect(rec.bwrapArgv.slice(-3)).toEqual(["/bin/bash", "-c", "echo hi"]);
    expect(basename(leafOf(rec))).toMatch(/^job-[a-f0-9]+$/);
    expect(dirname(leafOf(rec))).toBe(fx.envPath);
    await fx.jobs.killAll();
  });

  it("child output lands in the ring with rising endOffset; afterOffset skips covered bytes", async () => {
    const fx = await freshFixture();
    const info = await fx.jobs.start({ command: "worker" });
    const [rec] = fx.launcher.spawns;

    rec.child.stdout.write("j1\n");
    await tick;
    const first = fx.jobs.output(info.id)!;
    expect(first).not.toBeNull();
    expect(decode(first.chunks)).toBe("j1\n");
    expect(first.endOffset).toBe(3);
    expect(first.truncated).toBe(false);

    rec.child.stdout.write("j2\n");
    await tick;
    const second = fx.jobs.output(info.id, first.endOffset)!;
    expect(decode(second.chunks)).toBe("j2\n");
    expect(second.endOffset).toBe(6);
    // full read still reassembles everything
    expect(decode(fx.jobs.output(info.id)!.chunks)).toBe("j1\nj2\n");
    await fx.jobs.killAll();
  });

  it("a finished job records state exited with its exit code and removes its leaf", async () => {
    const fx = await freshFixture({ stdout: ["done\n"], exitCode: 0 });
    const info = await fx.jobs.start({ command: "echo done" });
    await until(() => fx.jobs.list()[0].state === "exited");
    const li = fx.jobs.list()[0];
    expect(li.state).toBe("exited");
    expect(li.exitCode).toBe(0);
    const out: JobOutput | null = fx.jobs.output(info.id);
    expect(out).not.toBeNull();
    expect(decode(out!.chunks)).toBe("done\n");
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
  });

  it("kill(id) → cgroups.kill on the job leaf, state 'killed'", async () => {
    const fx = await freshFixture();
    const info = await fx.jobs.start({ command: "sleep 300" });
    const [rec] = fx.launcher.spawns;
    const leaf = leafOf(rec);
    expect(existsSync(leaf)).toBe(true);

    await fx.jobs.kill(info.id);
    expect(existsSync(leaf)).toBe(false); // cgroup.kill removed the leaf
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
    const li = fx.jobs.list().find((j) => j.id === info.id)!;
    expect(li.state).toBe("killed");
    expect(li.exitCode).toBeNull();
    // the direct child was signalled too (belt under the tree kill)
    expect(rec.child.kills).toContain("SIGKILL");
    // output stays readable after the kill
    expect(fx.jobs.output(info.id)).not.toBeNull();
  });

  it("unknown id → output null, kill no-op", async () => {
    const fx = await freshFixture();
    expect(fx.jobs.output("nope")).toBeNull();
    await expect(fx.jobs.kill("nope")).resolves.toBeUndefined();
    expect(fx.jobs.list()).toEqual([]);
  });

  it("the 17th concurrent start throws job_limit", async () => {
    const fx = await freshFixture();
    const infos: JobInfo[] = [];
    for (let i = 0; i < 16; i++) {
      infos.push(await fx.jobs.start({ command: `sleep ${i + 1}` }));
    }
    expect(fx.jobs.size).toBe(16);
    expect(fx.jobs.list().every((j) => j.state === "running")).toBe(true);
    await expect(fx.jobs.start({ command: "sleep 17" })).rejects.toThrow("job_limit");
    expect(fx.jobs.size).toBe(16);
    await fx.jobs.killAll();
    await until(() => fx.jobs.list().every((j) => j.state === "killed"));
    expect(fx.jobs.list().every((j) => j.state === "killed")).toBe(true);
    // the freed slot admits a new job again
    const again = await fx.jobs.start({ command: "sleep 1" });
    expect(again.state).toBe("running");
    await fx.jobs.killAll();
  });
});

// ---------------------------------------------------------------------------
// spawnLongRunning (G3 — the P5 stdio-MCP backing)
// ---------------------------------------------------------------------------

describe("spawnLongRunning (G3)", () => {
  it("writeLine delivers the line + '\\n' to the child's stdin (appended when absent)", async () => {
    const fx = await freshFixture();
    const proc = await fx.run({ argv: ["node", "server.js"] });
    proc.writeLine('{"jsonrpc":"2.0","method":"ping"}');
    proc.writeLine("no-trailing-newline");
    await tick;
    const [rec] = fx.launcher.spawns;
    expect(rec.child.stdinData).toEqual([
      '{"jsonrpc":"2.0","method":"ping"}\n',
      "no-trailing-newline\n",
    ]);
    // argv only — the payload is the raw argv, no shell, no policy layer
    expect(rec.bwrapArgv.slice(-2)).toEqual(["node", "server.js"]);
    await proc.kill();
  });

  it("two JSON lines in ONE stdout chunk → onStdoutLine fires twice, one line each; spawnPty NOT called", async () => {
    const fx = await freshFixture();
    const proc = await fx.run({ argv: ["node", "mcp.js"] });
    const lines: string[] = [];
    proc.onStdoutLine((line) => lines.push(line));
    const [rec] = fx.launcher.spawns;

    rec.child.stdout.write('{"jsonrpc":"2.0","id":1}\n{"jsonrpc":"2.0","id":2}\n');
    await tick;
    expect(lines).toEqual(['{"jsonrpc":"2.0","id":1}', '{"jsonrpc":"2.0","id":2}']);

    // a trailing empty line is dropped, partial lines buffer until the next \n
    rec.child.stdout.write("partial");
    await tick;
    expect(lines).toHaveLength(2);
    rec.child.stdout.write("-line\n");
    await tick;
    expect(lines).toEqual([
      '{"jsonrpc":"2.0","id":1}',
      '{"jsonrpc":"2.0","id":2}',
      "partial-line",
    ]);

    // PIPES, never a pty: tty echo/CRLF would corrupt the JSON-RPC channel
    expect(fx.launcher.ptySpawns).toHaveLength(0);
    await proc.kill();
  });

  it("a multi-byte character split across stdout chunks arrives intact (no U+FFFD)", async () => {
    const fx = await freshFixture();
    const proc = await fx.run({ argv: ["node", "mcp.js"] });
    const lines: string[] = [];
    proc.onStdoutLine((line) => lines.push(line));
    const [rec] = fx.launcher.spawns;

    // Bursty pipes split at arbitrary BYTE offsets: cut "é" (C3 A9) and the
    // 4-byte "😀" mid-character across three chunks. Decoding each chunk
    // independently corrupts the halves to U+FFFD; the splitter must buffer
    // raw bytes and decode only completed lines.
    const payload = Buffer.from('{"text":"héllo 😀"}\n', "utf8");
    const eAccent = payload.indexOf(Buffer.from("é", "utf8"));
    const emoji = payload.indexOf(Buffer.from("😀", "utf8"));
    expect(eAccent).toBeGreaterThan(0);
    expect(emoji).toBeGreaterThan(eAccent);
    rec.child.stdout.write(payload.subarray(0, eAccent + 1)); // é's first byte
    rec.child.stdout.write(payload.subarray(eAccent + 1, emoji + 2)); // ...through 😀's 2nd byte
    rec.child.stdout.write(payload.subarray(emoji + 2)); // rest + "\n"
    await tick;
    expect(lines).toEqual(['{"text":"héllo 😀"}']);
    expect(lines[0]).not.toContain("�");

    await proc.kill();
  });

  it("onExit fires with the stub exit code and the spawn-* leaf is removed from the tree", async () => {
    const fx = await freshFixture({ exitCode: 7 });
    const proc = await fx.run({ argv: ["/usr/local/bin/node", "x.js"] });
    const code = await new Promise<number | null>((resolve) => proc.onExit(resolve));
    expect(code).toBe(7);
    expect(await fx.mgr.listChildren(fx.envPath)).toEqual([]);
    const [rec] = fx.launcher.spawns;
    expect(basename(leafOf(rec))).toMatch(/^spawn-[a-f0-9]+$/);
  });

  it("kill() on a live child → cgroup.kill on its leaf; second call is idempotent", async () => {
    const fx = await freshFixture();
    const proc = await fx.run({ argv: ["sleep", "300"] });
    const [rec] = fx.launcher.spawns;
    const leaf = leafOf(rec);
    expect(existsSync(leaf)).toBe(true);

    const exited = new Promise<number | null>((resolve) => proc.onExit(resolve));
    await proc.kill();
    expect(existsSync(leaf)).toBe(false); // cgroup.kill removed the leaf
    expect(await exited).toBeNull(); // killed, not a natural exit code
    expect(rec.child.kills).toContain("SIGKILL");

    await expect(proc.kill()).resolves.toBeUndefined(); // idempotent
  });

  it("stdin never throws even after the child is gone", async () => {
    const fx = await freshFixture({ exitCode: 0 });
    const proc = await fx.run({ argv: ["/bin/true"] });
    await new Promise<number | null>((resolve) => proc.onExit(resolve));
    expect(() => proc.writeLine("late")).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// SandboxHandle wiring (Task 9 manager integration)
// ---------------------------------------------------------------------------

describe("SandboxHandle wiring — jobs / spawnProcess / ptys on one env", () => {
  it("handle.jobs and handle.spawnProcess leaves are siblings under the env cgroup", async () => {
    const fx = await freshManagerFixture();
    await fx.handle.jobs.start({ command: "sleep 300" });
    await fx.handle.spawnProcess({ argv: ["node", "mcp.js"] });
    expect(fx.launcher.spawns).toHaveLength(2);
    const leaves = fx.launcher.spawns.map(leafOf);
    for (const leaf of leaves) {
      expect(dirname(leaf)).toBe(fx.envPath);
    }
    expect(
      leaves.map((l) => basename(l).split("-")[0]).sort(),
    ).toEqual(["job", "spawn"]);
    await fx.handle.destroy();
  });

  it("createPty/getPty return the tracked session", async () => {
    const fx = await freshManagerFixture();
    const session = await fx.handle.createPty(
      { sessionId: "s1" },
      { onData: () => {}, onExit: () => {} },
    );
    expect(session.sessionId).toBe("s1");
    expect(fx.handle.getPty(session.id)).toBe(session);
    expect(fx.handle.getPty("unknown")).toBeUndefined();
    // the pty spawn went through spawnPty with the clamped default dims
    expect(fx.launcher.ptySpawns).toHaveLength(1);
    expect(fx.launcher.ptySpawns[0].cols).toBe(80);
    expect(fx.launcher.ptySpawns[0].rows).toBe(24);
    await fx.handle.destroy();
  });

  it("destroy kills live leaves (pty, job, spawn) FIRST, then the env cgroup", async () => {
    const fx = await freshManagerFixture();
    const pty = await fx.handle.createPty(
      { sessionId: "s1" },
      { onData: () => {}, onExit: () => {} },
    );
    const job = await fx.handle.jobs.start({ command: "sleep 300" });
    const proc = await fx.handle.spawnProcess({ argv: ["node", "mcp.js"] });
    const procExit = new Promise<number | null>((resolve) => proc.onExit(resolve));

    expect(fx.cgroups.killCalls).toEqual([]); // nothing killed yet
    await fx.handle.destroy();

    // Ordering: every leaf kill precedes the env kill (the LAST recorded).
    const kills = fx.cgroups.killCalls;
    expect(kills.length).toBeGreaterThanOrEqual(4);
    expect(kills[kills.length - 1]).toBe(fx.envPath);
    for (const k of kills.slice(0, -1)) {
      expect(dirname(k)).toBe(fx.envPath);
      expect(basename(k).split("-")[0] + "-").toMatch(/^(pty-|job-|spawn-)$/);
    }

    // everything is dead and gone
    expect(pty.alive).toBe(false);
    await pty.exit;
    expect(fx.handle.jobs.list().map((j) => j.id)).toContain(job.id);
    expect(fx.handle.jobs.list()[0].state).toBe("killed");
    expect(await procExit).toBeNull();
    expect(existsSync(fx.envPath)).toBe(false);
    expect(fx.manager.activeCount()).toBe(0);
    expect(fx.handle.getPty(pty.id)).toBeUndefined();
  });
});
