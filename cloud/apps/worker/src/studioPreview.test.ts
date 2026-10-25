import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import { PassThrough, type Writable } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import {
  createCgroupManager,
  loadSandboxConfig,
  type CgroupManager,
  type ChildProcessLike,
  type JailLauncher,
  type SandboxConfig,
  type SandboxHandle,
  type SandboxManager,
} from "@ovid/sandbox";

import { StudioPreviewCapacityError } from "../../../packages/db/src/studioPreviewStore.js";
import { adaptStudioPreviewRouteError } from "./studioPreviewRoutes.js";
import {
  STUDIO_PREVIEW_DEFAULT_LIMITS,
  StudioPreviewError,
  createJailedStudioPreviewProcessRunner,
  createStudioPreviewManager,
  type StudioPreviewManager,
  type StudioPreviewProcess,
  type StudioPreviewProcessRunner,
  type StudioPreviewRecord,
  type StudioPreviewStore,
  type StudioPreviewStorePatch,
} from "./studioPreview.js";

const ROOT = "/tmp/opencode";
const UID = "preview-user";
const SID = "00000000-0000-4000-8000-000000000008";
const T0 = Date.parse("2026-10-24T12:00:00.000Z");
const LIVE = new Set(["starting", "running", "stopping"]);
const cleanup: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) {
    try {
      await fn();
    } catch {
      // Each test's assertions still perform their own targeted cleanup check.
    }
  }
});

function clone<T>(value: T): T {
  return structuredClone(value);
}

/** Cross-instance fake: one shared lock AND one shared map, never one per facade. */
class AtomicPreviewStore {
  private readonly rows = new Map<string, StudioPreviewRecord>();
  private tail: Promise<void> = Promise.resolve();
  updatesUnavailable = false;
  readonly touchCalls: Array<{ id: string; generation: number; now: string }> = [];
  touchWrites = 0;
  afterTouch: (() => Promise<void>) | null = null;
  afterGetForUser: (() => Promise<void>) | null = null;

  private async exclusive<T>(fn: () => Promise<T> | T): Promise<T> {
    const previous = this.tail;
    let release!: () => void;
    this.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try {
      // Make a missing transaction/advisory lock observable as an oversubscription.
      await new Promise<void>((resolve) => setImmediate(resolve));
      return await fn();
    } finally {
      release();
    }
  }

  facade(): StudioPreviewStore {
    return {
      start: (record, caps) => this.exclusive(async () => {
        if (this.rows.has(record.id)) throw new Error("duplicate_preview");
        if (record.kind === "dev_server") {
          const live = [...this.rows.values()].filter(
            (row) => row.kind === "dev_server" && LIVE.has(row.status),
          );
          if (live.filter((row) => row.userId === record.userId).length >= caps.perUser) {
            throw new StudioPreviewError("per_user_capacity", "This account already has two previews running.");
          }
          if (live.length >= caps.global) {
            throw new StudioPreviewError("global_capacity", "Preview capacity is full. Retry shortly.");
          }
        }
        const saved = clone(record);
        this.rows.set(saved.id, saved);
        return clone(saved);
      }),
      getForUser: async (userId, sessionId, id) => {
        const result = [...this.rows.values()]
          .filter((row) => row.userId === userId && row.sessionId === sessionId && (id === undefined || row.id === id))
          .map(clone);
        if (this.afterGetForUser !== null) await this.afterGetForUser();
        return result;
      },
      getLive: async () => [...this.rows.values()].filter((row) => LIVE.has(row.status)).map(clone),
      update: (id, generation, patch) => this.exclusive(() => {
        if (this.updatesUnavailable) throw new Error("preview store unavailable");
        const current = this.rows.get(id);
        if (current === undefined || current.generation !== generation) return null;
        const next = {
          ...current,
          ...clone(patch),
          generation: current.generation + 1,
        } as StudioPreviewRecord;
        this.rows.set(id, next);
        return clone(next);
      }),
      touch: async (input) => {
        const written = await this.exclusive(() => {
          const current = this.rows.get(input.id);
          const at = Date.parse(input.now);
          if (
            current === undefined ||
            current.generation !== input.generation ||
            (current.status !== "starting" && current.status !== "running") ||
            Date.parse(current.expiresAt) <= at
          ) return false;
          const last = Date.parse(current.lastAccessAt ?? "");
          if (Number.isFinite(last) && at - last < 1_000) return false;
          this.rows.set(input.id, { ...current, lastAccessAt: input.now });
          this.touchWrites += 1;
          return true;
        });
        this.touchCalls.push(clone(input));
        const after = this.afterTouch;
        this.afterTouch = null;
        if (after !== null) await after();
        return written;
      },
      sweepExpired: async (now, limit) => [...this.rows.values()]
        .filter((row) => LIVE.has(row.status) && Date.parse(row.expiresAt) <= Date.parse(now))
        .slice(0, limit)
        .map(clone),
    };
  }

  async seed(record: StudioPreviewRecord): Promise<void> {
    this.rows.set(record.id, clone(record));
  }

  async get(id: string): Promise<StudioPreviewRecord> {
    const row = this.rows.get(id);
    if (row === undefined) throw new Error(`missing test row ${id}`);
    return clone(row);
  }

  async countLive(): Promise<number> {
    return [...this.rows.values()].filter((row) => LIVE.has(row.status)).length;
  }
}

interface FakeSpawn {
  argv: string[];
  cwd: string;
  env: Record<string, string>;
  port: number;
  projectDir: string;
  process: FakeProcess;
  output: (text: string) => void;
}

class FakeProcess implements StudioPreviewProcess {
  readonly processGroupId: string;
  readonly processId: number;
  kills = 0;
  killError: Error | null = null;
  private exited = false;
  private exitCode: number | null = null;
  private readonly exits: Array<(code: number | null) => void> = [];

  constructor(readonly previewId: string, pid: number) {
    this.processId = pid;
    this.processGroupId = `/fake-cgroup/${previewId}`;
  }

  onExit(cb: (code: number | null) => void): void {
    if (this.exited) cb(this.exitCode);
    else this.exits.push(cb);
  }

  exit(code: number | null): void {
    if (this.exited) return;
    this.exited = true;
    this.exitCode = code;
    for (const cb of this.exits.splice(0)) cb(code);
  }

  async kill(): Promise<void> {
    this.kills += 1;
    if (this.killError !== null) throw this.killError;
    this.exit(null);
  }
}

class FakeProcesses implements StudioPreviewProcessRunner {
  readonly spawns: FakeSpawn[] = [];
  readonly staleKills: string[] = [];
  readonly scripts: Array<(process: FakeProcess, output: (text: string) => void) => void> = [];

  async spawn(
    req: { previewId: string; argv: string[]; cwd: string; env: Record<string, string>; port: number; projectDir: string },
    onOutput: (chunk: Buffer) => void,
  ): Promise<StudioPreviewProcess> {
    const process = new FakeProcess(req.previewId, 4000 + this.spawns.length);
    const call = { ...req, process, output: (text: string) => onOutput(Buffer.from(text)) };
    this.spawns.push(call);
    const script = this.scripts.shift();
    if (script !== undefined) queueMicrotask(() => script(process, (text) => onOutput(Buffer.from(text))));
    return process;
  }

  async killStale(record: StudioPreviewRecord): Promise<void> {
    this.staleKills.push(record.id);
    for (const call of this.spawns) {
      if (call.process.processGroupId === record.processGroupId) await call.process.kill();
    }
  }
}

class FakeSandbox {
  readonly handle: SandboxHandle;
  constructor(readonly workspace: string, readonly sessions: string) {
    this.handle = {
      userId: UID,
      uid: 200001,
      workspaceDir: workspace,
      homeDir: join(workspace, ".home"),
      jailWorkspaceDir: "/workspace",
    } as SandboxHandle;
  }

  manager(): Pick<SandboxManager, "attach" | "workspaceDir"> {
    return {
      attach: async (userId) => ({ ...this.handle, userId }),
      workspaceDir: async (_userId, sessionId) => {
        const dir = join(this.sessions, sessionId);
        await mkdir(dir, { recursive: true, mode: 0o700 });
        return dir;
      },
    };
  }
}

interface Harness {
  store: AtomicPreviewStore;
  processes: FakeProcesses;
  manager: StudioPreviewManager;
  workspace: string;
  sessions: string;
  now: () => number;
  advance: (ms: number) => void;
  newManager: (workerEpoch?: string) => StudioPreviewManager;
}

async function harness(options: {
  shared?: AtomicPreviewStore;
  limits?: Partial<typeof STUDIO_PREVIEW_DEFAULT_LIMITS>;
  workerEpoch?: string;
  autoReady?: boolean;
  workspaceDirError?: boolean;
  binding?: { get: (identity: { userId: string; sessionId: string }) => Promise<{
    userId: string;
    sessionId: string;
    repo: string;
    repoDir: string;
    branch: string;
    createdAt: Date;
    updatedAt: Date;
  } | null> };
  allocatePort?: (reserved: ReadonlySet<number>) => Promise<number>;
} = {}): Promise<Harness> {
  const root = await mkdtemp(join(ROOT, "studio-preview-test-"));
  cleanup.push(() => rm(root, { recursive: true, force: true }));
  const workspace = join(root, "workspace");
  const sessions = join(root, "sessions");
  await mkdir(join(workspace, "app"), { recursive: true });
  await mkdir(sessions, { recursive: true });
  await writeFile(join(workspace, "app", "package.json"), JSON.stringify({
    scripts: { dev: "node server.js", start: "node server.js", preview: "node server.js" },
  }));
  await writeFile(join(workspace, "app", "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n");
  await writeFile(join(workspace, "app", "index.html"), "<h1>safe</h1>");
  const sandbox = new FakeSandbox(workspace, sessions);
  const store = options.shared ?? new AtomicPreviewStore();
  const processes = new FakeProcesses();
  const sandboxManager = sandbox.manager();
  if (options.workspaceDirError === true) {
    sandboxManager.workspaceDir = async () => {
      throw new Error("session log directory unavailable");
    };
  }
  let current = T0;
  const managers: StudioPreviewManager[] = [];
  cleanup.push(async () => {
    for (const manager of managers.reverse()) await manager.close();
  });
  const newManager = (workerEpoch = options.workerEpoch ?? "worker-test") => {
    const manager = createStudioPreviewManager({
      store: store.facade(),
      manager: sandboxManager,
      binding: options.binding ?? {
        get: async ({ userId, sessionId }) => ({
          userId,
          sessionId,
          repo: "acme/app",
          repoDir: "app",
          branch: "main",
          createdAt: new Date(T0),
          updatedAt: new Date(T0),
        }),
      },
      processes,
      redact: (text) => text
        .replace(/(authorization\s*:\s*)[^\r\n]+/gi, "$1[REDACTED]")
        .replace(/(token\s*:\s*)[^\r\n]+/gi, "$1[REDACTED]"),
      now: () => current,
      workerEpoch,
      ...(options.limits !== undefined ? { limits: options.limits } : {}),
      probe: async () => options.autoReady !== false,
      sleep: async (ms) => { current += ms; },
      allocatePort: options.allocatePort ?? (() => {
        let port = 20000;
        return async (reserved) => {
          while (reserved.has(port)) port += 1;
          return port++;
        };
      })(),
    });
    managers.push(manager);
    return manager;
  };
  const manager = newManager();
  return {
    store,
    processes,
    manager,
    workspace,
    sessions,
    now: () => current,
    advance: (ms) => { current += ms; },
    newManager,
  };
}

function devRequest(userId = UID, sessionId = SID) {
  return { userId, sessionId, kind: "dev_server" as const, projectDir: "app", script: "dev" as const };
}

function staticRequest(userId = UID, sessionId = SID) {
  return { userId, sessionId, kind: "static" as const, workspacePath: "app" };
}

async function waitFor(assertion: () => Promise<boolean>, attempts = 100): Promise<void> {
  for (let i = 0; i < attempts; i++) {
    if (await assertion()) return;
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
  throw new Error("condition did not become true");
}

describe("Studio preview lifecycle", () => {
  it("UNEXECUTED: adapts the concrete DB capacity error to the safe 429 error vocabulary", () => {
    const adapted = adaptStudioPreviewRouteError(
      new StudioPreviewCapacityError("per_user_capacity"),
    );
    expect(adapted).toMatchObject({
      code: "per_user_capacity",
      message: "This account has reached its preview process limit.",
    });
  });

  it("UNEXECUTED: retains cleanup_unproven admission when cgroup identity is unknown", async () => {
    const h = await harness();
    const record = await h.manager.start(staticRequest());
    await h.store.seed({
      ...record,
      kind: "dev_server",
      status: "running",
      projectDir: join(h.workspace, "app"),
      startScript: "dev",
      workerEpoch: "worker-test",
      bindHost: "127.0.0.1",
      port: 20000,
      logBytes: 0,
      processId: 12345,
      processGroupId: null,
    });
    await expect(h.newManager("worker-test").sweep()).rejects.toMatchObject({ code: "cleanup_unproven" });
    expect(await h.store.get(record.id)).toMatchObject({
      status: "stopping",
      failureCode: "cleanup_unproven",
    });
    expect(await h.store.countLive()).toBe(1);
  });

  it("pins nullable records, exact TTLs, DTO secrecy, and fixed package-manager launch", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    expect(started).toMatchObject({
      generation: expect.any(Number),
      kind: "dev_server",
      status: "running",
      workspacePath: await realpath(h.workspace),
      projectDir: await realpath(join(h.workspace, "app")),
      startScript: "dev",
      bindHost: "127.0.0.1",
      port: 20000,
      lastAccessAt: null,
      endedAt: null,
      exitCode: null,
      failureCode: null,
      logBytes: 0,
      createdAt: new Date(T0).toISOString(),
      expiresAt: new Date(T0 + 15 * 60_000).toISOString(),
    });
    expect(started.processId).not.toBeNull();
    expect(started.processGroupId).not.toBeNull();
    expect(started.workerEpoch).toBe("worker-test");
    expect(h.processes.spawns[0]).toMatchObject({
      argv: ["pnpm", "run", "dev", "--host", "127.0.0.1", "--port", "20000", "--strictPort"],
      cwd: "/workspace/app",
      env: { HOST: "127.0.0.1", HOSTNAME: "127.0.0.1", PORT: "20000", NODE_ENV: "development" },
    });
    expect(h.processes.spawns[0]!.env).not.toHaveProperty("OVID_MASTER_KEY");
    expect(STUDIO_PREVIEW_DEFAULT_LIMITS).toEqual({
      perUser: 2,
      global: 32,
      startupMs: 30_000,
      idleMs: 15 * 60_000,
      absoluteMs: 60 * 60_000,
      logCapBytes: 256 * 1024,
      portMin: 20000,
      portMax: 29999,
      bindHost: "127.0.0.1",
    });

    const staticPreview = await h.manager.start(staticRequest());
    expect(staticPreview).toMatchObject({
      kind: "static",
      status: "running",
      processId: null,
      processGroupId: null,
      workerEpoch: null,
      bindHost: null,
      port: null,
      startScript: null,
      logBytes: null,
    });
  });

  it("never reallocates the admitted port during normal startup", async () => {
    const shared = new AtomicPreviewStore();
    const store = shared.facade();
    const h = await harness({
      shared,
      allocatePort: async () => {
        // A second allocation after store.start would see the admitted row.
        // Returning a fresh port here models a real allocator, not a spy.
        const admitted = (await store.getLive()).find((row) => row.workerEpoch === "worker-test");
        if (admitted !== undefined) throw new Error("port allocated after admission");
        return 20000;
      },
    });
    const started = await h.manager.start(devRequest());
    expect(started).toMatchObject({ status: "running", port: 20000 });
    expect(h.processes.spawns.map((call) => call.port)).toEqual([20000]);
  });

  it("denies the third per-user process at the atomic store boundary before spawn", async () => {
    const h = await harness();
    await Promise.all([h.manager.start(devRequest()), h.manager.start(devRequest())]);
    const before = h.processes.spawns.length;
    await expect(h.manager.start(devRequest())).rejects.toMatchObject({ code: "per_user_capacity" });
    expect(h.processes.spawns).toHaveLength(before);
    expect(await h.store.countLive()).toBe(2);
  });

  it("keeps the global cap at 32 across racing manager instances", async () => {
    const shared = new AtomicPreviewStore();
    const h = await harness({ shared });
    const second = h.newManager("worker-second");
    const third = h.newManager("worker-third");
    const managers = [h.manager, second, third];
    const attempts = await Promise.allSettled(Array.from({ length: 33 }, (_, i) =>
      managers[i % 3]!.start(devRequest(`global-user-${i}`, SID)),
    ));
    expect(attempts.filter((result) => result.status === "fulfilled")).toHaveLength(32);
    const denied = attempts.filter((result) => result.status === "rejected");
    expect(denied).toHaveLength(1);
    expect((denied[0] as PromiseRejectedResult).reason).toMatchObject({ code: "global_capacity" });
    expect(h.processes.spawns).toHaveLength(32);
    expect(await shared.countLive()).toBe(32);
  });

  it("rejects escaping, absolute, symlinked, and undeclared definitions before spawn", async () => {
    const h = await harness();
    await symlink("/etc", join(h.workspace, "escape"));
    await symlink("/etc/passwd", join(h.workspace, "app", "package.json"));
    await expect(h.manager.start(devRequest())).rejects.toMatchObject({ code: "invalid_path" });
    const invalid = [
      { ...devRequest(), projectDir: "../outside" },
      { ...devRequest(), projectDir: "/etc" },
      { ...devRequest(), projectDir: "escape" },
      { ...devRequest(), projectDir: "app", script: "missing" },
      { ...devRequest(), projectDir: "app", script: "dev", command: "id" },
    ];
    for (const request of invalid) {
      await expect(h.manager.start(request as never)).rejects.toMatchObject({
        code: expect.stringMatching(/invalid_request|invalid_path|invalid_script/),
      });
    }
    expect(h.processes.spawns).toHaveLength(0);
  });

  it("UNEXECUTED: confines dev launch to the canonical session repository binding", async () => {
    const h = await harness();
    await mkdir(join(h.workspace, "other"));
    await writeFile(join(h.workspace, "other", "package.json"), JSON.stringify({
      scripts: { dev: "node server.js" },
    }));
    await expect(h.manager.start({
      ...devRequest(),
      projectDir: "other",
    })).rejects.toMatchObject({ code: "invalid_path" });
    expect(h.processes.spawns).toHaveLength(0);

    const unbound = await harness({ binding: { get: async () => null } });
    await expect(unbound.manager.start(devRequest())).rejects.toMatchObject({ code: "no_repo" });
    expect(unbound.processes.spawns).toHaveLength(0);
  });

  it("refuses a public bind configuration before any child starts", async () => {
    await expect(harness({ limits: { bindHost: "0.0.0.0" } })).rejects.toMatchObject({ code: "invalid_bind" });
  });

  it("retries an actual EADDRINUSE startup on a fresh allowlisted port", async () => {
    const h = await harness();
    h.processes.scripts.push((process, output) => {
      output("Error: listen EADDRINUSE: address already in use\n");
      process.exit(1);
    });
    const started = await h.manager.start(devRequest());
    expect(started).toMatchObject({ status: "running", port: 20001 });
    expect(h.processes.spawns.map((call) => call.port)).toEqual([20000, 20001]);
    expect(h.processes.spawns[0]!.process.kills).toBe(1);
  });

  it("UNEXECUTED: retries a content-generation conflict before confirming readiness", async () => {
    const h = await harness();
    let reads = 0;
    h.store.afterGetForUser = async () => {
      reads += 1;
      if (reads !== 2) return;
      h.store.afterGetForUser = null;
      const current = (await h.store.facade().getLive())[0]!;
      await h.store.facade().update(current.id, current.generation, { logBytes: 1 });
    };
    const started = await h.manager.start(devRequest());
    expect(started).toMatchObject({ status: "running", logBytes: 1 });
    expect(h.processes.spawns).toHaveLength(1);
  });

  it("UNEXECUTED: exhausted readiness conflicts remain sweep-recoverable after startup grace", async () => {
    const h = await harness();
    let reads = 0;
    h.store.afterGetForUser = async () => {
      reads += 1;
      if (reads < 2) return; // allow the spawned process identity to register
      const current = (await h.store.facade().getLive())[0];
      if (current?.status === "starting") {
        await h.store.facade().update(current.id, current.generation, {
          logBytes: (current.logBytes ?? 0) + 1,
        });
      }
    };
    await expect(h.manager.start(devRequest())).rejects.toMatchObject({
      code: "cleanup_unproven",
    });
    expect(h.processes.spawns).toHaveLength(1);
    expect(h.processes.spawns[0]!.process.kills).toBe(0);
    expect(await h.store.countLive()).toBe(1);

    h.store.afterGetForUser = null;
    h.advance(30_000);
    expect(await h.manager.sweep()).toBe(1);
    const expired = (await h.store.facade().getLive());
    expect(expired).toHaveLength(0);
    expect(h.processes.spawns[0]!.process.kills).toBe(1);
    const stored = (await h.store.facade().getForUser(UID, SID))[0]!;
    expect(stored).toMatchObject({ status: "failed", failureCode: "startup_timeout" });
  });

  it("UNEXECUTED: stop and sweep retry CAS conflicts and confirm terminal state", async () => {
    const stoppedHarness = await harness();
    const started = await stoppedHarness.manager.start(devRequest());
    let reads = 0;
    stoppedHarness.store.afterGetForUser = async () => {
      reads += 1;
      if (reads !== 2) return;
      stoppedHarness.store.afterGetForUser = null;
      const current = await stoppedHarness.store.get(started.id);
      await stoppedHarness.store.facade().update(current.id, current.generation, { logBytes: 1 });
    };
    expect(await stoppedHarness.manager.stop({
      userId: UID, sessionId: SID, id: started.id,
    })).toMatchObject({ status: "stopped" });
    expect(stoppedHarness.processes.spawns[0]!.process.kills).toBe(1);

    const sweptHarness = await harness();
    const expired = await sweptHarness.manager.start(devRequest());
    sweptHarness.advance(15 * 60_000);
    sweptHarness.store.afterGetForUser = async () => {
      sweptHarness.store.afterGetForUser = null;
      const current = await sweptHarness.store.get(expired.id);
      await sweptHarness.store.facade().update(current.id, current.generation, { logBytes: 1 });
    };
    expect(await sweptHarness.manager.sweep()).toBe(1);
    expect(await sweptHarness.store.get(expired.id)).toMatchObject({ status: "expired" });
  });

  it("UNEXECUTED: repeated stop CAS conflicts never return a running success", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    h.store.afterGetForUser = async () => {
      const current = await h.store.get(started.id);
      if (current.status === "running") {
        await h.store.facade().update(current.id, current.generation, {
          logBytes: (current.logBytes ?? 0) + 1,
        });
      }
    };
    await expect(h.manager.stop({
      userId: UID, sessionId: SID, id: started.id,
    })).rejects.toMatchObject({ code: "lifecycle_conflict" });
    expect(await h.store.get(started.id)).toMatchObject({ status: "running" });
    expect(h.processes.spawns[0]!.process.kills).toBe(0);
    expect(await h.store.countLive()).toBe(1);
  });

  it("times out startup, kills the whole owned runtime, and releases capacity", async () => {
    const h = await harness({ autoReady: false });
    const started = await h.manager.start(devRequest());
    expect(started).toMatchObject({ status: "failed", failureCode: "startup_timeout", endedAt: expect.any(String) });
    expect(h.processes.spawns[0]!.process.kills).toBe(1);
    expect(await h.store.countLive()).toBe(0);
  });

  it("marks an early process exit failed without inventing an exit code", async () => {
    const h = await harness();
    h.processes.scripts.push((process) => process.exit(null));
    const started = await h.manager.start(devRequest());
    expect(started).toMatchObject({ status: "failed", failureCode: "startup_failed", exitCode: null });
    expect(await h.store.countLive()).toBe(0);
  });

  it("releases admission when log setup fails before a process exists", async () => {
    const h = await harness({ workspaceDirError: true });
    await expect(h.manager.start(devRequest())).rejects.toThrow();
    expect(h.processes.spawns).toHaveLength(0);
    expect(await h.store.countLive()).toBe(0);
  });

  it("kills the spawned cgroup even if the store fails during registration", async () => {
    const shared = new AtomicPreviewStore();
    const h = await harness({ shared });
    shared.updatesUnavailable = true;
    await expect(h.manager.start(devRequest())).rejects.toMatchObject({ code: "startup_failed" });
    expect(h.processes.spawns).toHaveLength(1);
    expect(h.processes.spawns[0]!.process.kills).toBe(1);
  });

  it("does not release a naturally exited preview until cgroup cleanup succeeds", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    const process = h.processes.spawns[0]!.process;
    process.killError = new Error("cgroup still busy");
    process.exit(1);
    await waitFor(async () => (await h.store.get(started.id)).status === "stopping");
    expect(process.kills).toBe(1);
    expect(await h.store.get(started.id)).toMatchObject({ status: "stopping" });
    process.killError = null;
    await h.manager.close();
    expect(await h.store.get(started.id)).toMatchObject({ status: "stopped", failureCode: "shutdown" });
  });

  it("terminates a continuous output flood once without queueing unbounded writes", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    const call = h.processes.spawns[0]!;
    for (let i = 0; i < 64; i++) call.output("x".repeat(16 * 1024));
    await waitFor(async () => (await h.store.get(started.id)).status === "failed");
    expect(await h.store.get(started.id)).toMatchObject({ failureCode: "output_limit" });
    expect(call.process.kills).toBe(1);
    expect(await h.store.countLive()).toBe(0);
  });

  it("caps redacted logs at 256 KiB and kills an output flood", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    const call = h.processes.spawns[0]!;
    call.output("Authorization: Bearer preview-canary\n");
    call.output("x".repeat(256 * 1024));
    await waitFor(async () => (await h.store.get(started.id)).status === "failed");
    const flooded = await h.store.get(started.id);
    expect(flooded).toMatchObject({ status: "failed", failureCode: "output_limit" });
    expect(flooded.logBytes).not.toBeNull();
    expect(flooded.logBytes!).toBeGreaterThan(0);
    expect(flooded.logBytes!).toBeLessThanOrEqual(256 * 1024);
    expect(call.process.kills).toBe(1);
    const logDir = join(h.sessions, SID, ".ovid", "previews");
    const logPath = join(logDir, `${started.id}.log`);
    const bytes = await readFile(logPath, "utf8");
    expect(Buffer.byteLength(bytes, "utf8")).toBeLessThanOrEqual(256 * 1024);
    expect(bytes).not.toContain("preview-canary");
    expect(bytes).toContain("[REDACTED]");
    expect((await stat(logPath)).mode & 0o777).toBe(0o600);
    expect((await stat(logDir)).mode & 0o777).toBe(0o700);
    expect(await h.manager.logs({ userId: UID, sessionId: SID, id: started.id })).toMatchObject({
      truncated: true,
    });
    expect(await h.store.countLive()).toBe(0);
  });

  it("UNEXECUTED: maps DB boolean touch to a record and changes only lastAccessAt", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    const before = await h.store.get(started.id);
    h.advance(1_000);
    const touched = await h.manager.touch({
      userId: UID,
      sessionId: SID,
      id: started.id,
      generation: started.generation,
      kind: "dev_server",
      now: new Date(h.now()),
    });
    expect(touched).not.toBe(true);
    expect(touched).not.toBe(false);
    expect(touched).toMatchObject({
      id: started.id,
      generation: before.generation,
      status: "running",
      lastAccessAt: new Date(T0 + 1_000).toISOString(),
    });
    const after = await h.store.get(started.id);
    expect({ ...after, lastAccessAt: before.lastAccessAt }).toEqual(before);

    const throttled = await h.manager.touch({
      userId: UID,
      sessionId: SID,
      id: started.id,
      generation: started.generation,
      kind: "dev_server",
      now: new Date(h.now()),
    });
    expect(throttled).toMatchObject({
      generation: before.generation,
      status: "running",
      lastAccessAt: after.lastAccessAt,
    });
    expect(h.store.touchCalls).toHaveLength(2);
    expect(h.store.touchWrites).toBe(1);
  });

  it("UNEXECUTED: active access still writes after the initial idle window", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    h.advance(14 * 60_000);
    const at = () => ({
      userId: UID, sessionId: SID, id: started.id,
      generation: started.generation, kind: "dev_server" as const,
      now: new Date(h.now()),
    });
    expect(await h.manager.touch(at())).not.toBeNull();
    h.advance(2 * 60_000);
    expect(await h.manager.touch(at())).toMatchObject({
      generation: started.generation,
      status: "running",
      lastAccessAt: new Date(T0 + 16 * 60_000).toISOString(),
    });
    expect(h.store.touchWrites).toBe(2);
  });

  it.each([
    ["stopped", { status: "stopped" } as const],
    ["changed content generation", { port: 20002 } as const],
  ])("UNEXECUTED: throttled touch revalidates authoritative %s", async (_name, patch) => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    const first = await h.manager.touch({
      userId: UID,
      sessionId: SID,
      id: started.id,
      generation: started.generation,
      kind: "dev_server",
      now: new Date(h.now()),
    });
    expect(first).not.toBeNull();
    h.store.afterTouch = async () => {
      const current = await h.store.get(started.id);
      await h.store.facade().update(current.id, current.generation, patch);
    };
    const denied = await h.manager.touch({
      userId: UID,
      sessionId: SID,
      id: started.id,
      generation: started.generation,
      kind: "dev_server",
      now: new Date(h.now()),
    });
    expect(denied).toBeNull();
    expect(h.store.touchCalls).toHaveLength(2);
    expect(h.store.touchWrites).toBe(1);
  });

  it("UNEXECUTED: stale, stopped, expired, and wrong-kind access never reaches atomic touch", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    expect(await h.manager.touch({
      userId: UID, sessionId: SID, id: started.id,
      generation: started.generation + 1, kind: "dev_server",
    })).toBeNull();
    expect(await h.manager.touch({
      userId: UID, sessionId: SID, id: started.id,
      generation: started.generation, kind: "static",
    })).toBeNull();
    await h.manager.stop({ userId: UID, sessionId: SID, id: started.id });
    const stopped = await h.store.get(started.id);
    expect(await h.manager.touch({
      userId: UID, sessionId: SID, id: stopped.id,
      generation: stopped.generation, kind: "dev_server",
    })).toBeNull();

    const expiredHarness = await harness();
    const expired = await expiredHarness.manager.start(devRequest());
    expiredHarness.advance(15 * 60_000);
    expect(await expiredHarness.manager.touch({
      userId: UID, sessionId: SID, id: expired.id,
      generation: expired.generation, kind: "dev_server",
    })).toBeNull();
    expect(h.store.touchCalls).toHaveLength(0);
    expect(expiredHarness.store.touchCalls).toHaveLength(0);
  });

  it("UNEXECUTED: never slides an already expired registration on a read", async () => {
    const h = await harness();
    const started = await h.manager.start(devRequest());
    const before = await h.store.get(started.id);
    h.advance(15 * 60_000);
    const read = await h.manager.get({ userId: UID, sessionId: SID, id: started.id });
    expect(read).toMatchObject({
      lastAccessAt: before.lastAccessAt,
      expiresAt: before.expiresAt,
    });
    expect(await h.store.get(started.id)).toMatchObject({
      lastAccessAt: before.lastAccessAt,
      expiresAt: before.expiresAt,
    });
  });

  it("expires idle and absolute previews and releases their process slots", async () => {
    const idle = await harness();
    const started = await idle.manager.start(devRequest());
    idle.advance(15 * 60_000);
    expect(await idle.manager.sweep()).toBe(1);
    expect(await idle.store.get(started.id)).toMatchObject({ status: "expired", failureCode: "idle_expired" });
    expect(idle.processes.spawns[0]!.process.kills).toBe(1);
    expect(await idle.store.countLive()).toBe(0);

    const absolute = await harness();
    const other = await absolute.manager.start(devRequest());
    absolute.advance(59 * 60_000);
    await absolute.manager.get({ userId: UID, sessionId: SID, id: other.id });
    absolute.advance(60_000);
    expect(await absolute.manager.sweep()).toBe(1);
    expect(await absolute.store.get(other.id)).toMatchObject({ status: "expired", failureCode: "absolute_expired" });
    expect(absolute.processes.spawns[0]!.process.kills).toBe(1);
  });

  it("UNEXECUTED: stops and closes static registrations without process cleanup", async () => {
    const h = await harness();
    const stopped = await h.manager.start(staticRequest());
    const result = await h.manager.stop({ userId: UID, sessionId: SID, id: stopped.id });
    expect(result).toMatchObject({ status: "stopped", kind: "static", processId: null });
    expect(h.processes.spawns).toHaveLength(0);

    const closing = await h.manager.start(staticRequest(UID, "static-close"));
    await h.manager.close();
    expect(await h.store.get(closing.id)).toMatchObject({ status: "stopped", failureCode: "shutdown" });
  });

  it("stops, deletes, hibernates, and closes without stale exit transitions", async () => {
    const h = await harness();
    const stopped = await h.manager.start(devRequest());
    const stopping = h.manager.stop({ userId: UID, sessionId: SID, id: stopped.id });
    await waitFor(async () => (await h.store.get(stopped.id)).status === "stopping");
    h.processes.spawns[0]!.process.exit(0);
    await stopping;
    expect(await h.store.get(stopped.id)).toMatchObject({ status: "stopped", failureCode: null, exitCode: null });

    const deleted = await h.manager.start(devRequest(UID, "delete-session"));
    expect(await h.manager.stopSession({ userId: UID, sessionId: "delete-session", reason: "delete" })).toBe(1);
    expect(await h.store.get(deleted.id)).toMatchObject({ status: "stopped", failureCode: "deleted" });

    const hibernated = await h.manager.start(devRequest(UID, "hibernate-session"));
    expect(await h.manager.stopSession({ userId: UID, sessionId: "hibernate-session", reason: "hibernate" })).toBe(1);
    expect(await h.store.get(hibernated.id)).toMatchObject({ status: "stopped", failureCode: "hibernated" });

    const shutdown = await h.manager.start(devRequest(UID, "shutdown-session"));
    await h.manager.close();
    expect(await h.store.get(shutdown.id)).toMatchObject({ status: "stopped", failureCode: "shutdown" });
    await expect(h.manager.start(devRequest())).rejects.toMatchObject({ code: "preview_closed" });
  });

  it("cleans a stale same-worker cgroup without killing a reused unrelated PID", async () => {
    const h = await harness();
    const stale = await h.manager.start(devRequest());
    const process = h.processes.spawns[0]!.process;
    // A restarted manager has no in-memory runtime, but has the same stable worker epoch.
    const recovered = h.newManager("worker-test");
    await recovered.sweep();
    expect(h.processes.staleKills).toContain(stale.id);
    expect(process.kills).toBe(1);
    expect(await h.store.get(stale.id)).toMatchObject({ status: "failed", failureCode: "stale_process" });
  });
});

// ---------------------------------------------------------------------------
// Real local process proof for the low-level jailed-runner contract.
// The launcher below deliberately substitutes an unjailed, detached local
// payload. It preserves argv/env/cwd/cgroup-identity behavior, but is NOT
// claimed as bwrap/kernel-cgroup evidence.
// ---------------------------------------------------------------------------

class LocalCgroups implements CgroupManager {
  private readonly inner: CgroupManager;
  private killTail: Promise<void> = Promise.resolve();
  killError: Error | null = null;
  constructor(config: SandboxConfig) {
    this.inner = createCgroupManager(config);
  }
  init() { return this.inner.init(); }
  envPath(uid: number) { return this.inner.envPath(uid); }
  leafPath(uid: number, name: string) { return this.inner.leafPath(uid, name); }
  createEnv(uid: number, limits: Parameters<CgroupManager["createEnv"]>[1]) { return this.inner.createEnv(uid, limits); }
  createLeaf(uid: number, name: string) { return this.inner.createLeaf(uid, name); }
  attachPid(path: string, pid: number) { return this.inner.attachPid(path, pid); }
  procsFile(path: string) { return this.inner.procsFile(path); }
  readFile(path: string, file: string) { return this.inner.readFile(path, file); }
  listChildren(path: string) { return this.inner.listChildren(path); }
  remove(path: string) { return this.inner.remove(path); }

  kill(path: string): Promise<void> {
    // cgroupfs serializes removal of a leaf; the tmpdir simulation must also
    // prevent two unlink/rmdir passes from interleaving interface files.
    const result = this.killTail.then(() => this.killSerialized(path));
    this.killTail = result.catch(() => {});
    return result;
  }

  private async killSerialized(path: string): Promise<void> {
    if (this.killError !== null) throw this.killError;
    let pids: number[] = [];
    try {
      pids = (await readFile(join(path, "cgroup.procs"), "utf8"))
        .split(/\s+/).filter(Boolean).map(Number).filter((pid) => Number.isInteger(pid) && pid > 1);
    } catch {
      return;
    }
    for (const pid of pids) {
      if (pid === process.pid) throw new Error("local cgroup refused to kill the test runner");
      try { process.kill(-pid, "SIGKILL"); } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== "ESRCH") throw err;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 30));
    await writeFile(join(path, "cgroup.procs"), "", "utf8");
    await this.inner.kill(path);
  }
}

function adaptChild(child: ChildProcess): ChildProcessLike {
  return {
    pid: child.pid ?? -1,
    stdout: child.stdout,
    stderr: child.stderr,
    stdin: child.stdin,
    kill: (signal) => child.kill(signal),
    once: (event, listener) => { child.once(event as "exit", listener as never); },
  };
}

class LocalLauncher implements JailLauncher {
  readonly children: ChildProcess[] = [];
  constructor(readonly spawnError: Error | null = null) {}
  spawn(argv: string[], opts: { cgroupProcsFile: string; cwd: string }): ChildProcessLike {
    if (this.spawnError !== null) throw this.spawnError;
    const chdir = argv.indexOf("--chdir");
    if (chdir < 0 || argv[chdir + 1] === undefined) throw new Error("missing jail cwd");
    const payload = argv.slice(chdir + 2);
    const env: Record<string, string> = {};
    for (let i = 0; i < argv.length - 1; i++) {
      if (argv[i] === "--setenv") env[argv[i + 1]!] = argv[i + 2]!;
    }
    const jailCwd = argv[chdir + 1]!;
    const relative = jailCwd === "/workspace" ? "" : jailCwd.slice("/workspace/".length);
    const child = spawn(payload[0]!, payload.slice(1), {
      cwd: resolve(opts.cwd, relative),
      env,
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.children.push(child);
    // The real launcher self-attaches before dropping privileges. This local
    // stand-in records the same identity atomically from the parent.
    requireWrite(opts.cgroupProcsFile, String(child.pid));
    return adaptChild(child);
  }
  spawnPty(): never { throw new Error("not used"); }
}

function requireWrite(path: string, value: string): void {
  // Synchronous by design: launcher.spawn returns before the caller can race a
  // readiness probe against a missing identity.
  writeFileSync(path, value, "utf8");
}

interface LocalHarness {
  manager: StudioPreviewManager;
  recovered: StudioPreviewManager;
  store: AtomicPreviewStore;
  launcher: LocalLauncher;
  cgroups: LocalCgroups;
  closeAll: () => Promise<void>;
}

async function localHarness(options: {
  spawnError?: Error;
  killError?: Error;
} = {}): Promise<LocalHarness> {
  const root = await mkdtemp(join(ROOT, "studio-preview-local-"));
  const workspace = join(root, "workspace");
  const sessions = join(root, "sessions");
  await mkdir(join(workspace, "app"), { recursive: true });
  await mkdir(sessions, { recursive: true });
  await writeFile(join(workspace, "app", "package.json"), JSON.stringify({
    scripts: { dev: "node server.js" },
  }));
  await writeFile(join(workspace, "app", "server.js"), `
    const http = require("node:http");
    const args = process.argv;
    const port = Number(args[args.indexOf("--port") + 1] || process.env.PORT);
    const host = args[args.indexOf("--host") + 1] || process.env.HOST;
    http.createServer((_req, res) => res.end("local-ok")).listen(port, host);
  `);
  const config: SandboxConfig = {
    ...loadSandboxConfig({}),
    workspacesRoot: workspace,
    cgroupRoot: join(root, "cgroups"),
    cgroupBase: "preview-local",
  };
  await mkdir(join(config.cgroupRoot, config.cgroupBase), { recursive: true });
  const cgroups = new LocalCgroups(config);
  cgroups.killError = options.killError ?? null;
  await cgroups.init();
  const launcher = new LocalLauncher(options.spawnError ?? null);
  const sandbox = new FakeSandbox(workspace, sessions);
  const sandboxManager = sandbox.manager();
  const attach = sandboxManager.attach;
  let envCreated = false;
  sandboxManager.attach = async (userId) => {
    const handle = await attach(userId);
    if (!envCreated) {
      await cgroups.createEnv(handle.uid, config.limits);
      envCreated = true;
    }
    return handle;
  };
  const processes = createJailedStudioPreviewProcessRunner({
    manager: sandboxManager,
    cgroups,
    launcher,
    config,
    rootfs: "/not-used-by-local-launcher",
  });
  const store = new AtomicPreviewStore();
  const managers: StudioPreviewManager[] = [];
  const make = () => {
    const manager = createStudioPreviewManager({
      store: store.facade(),
      manager: sandboxManager,
      binding: {
        get: async ({ userId, sessionId }) => ({
          userId,
          sessionId,
          repo: "acme/app",
          repoDir: "app",
          branch: "main",
          createdAt: new Date(T0),
          updatedAt: new Date(T0),
        }),
      },
      processes,
      redact: (text) => text,
      workerEpoch: "local-stable-worker",
    });
    managers.push(manager);
    return manager;
  };
  const manager = make();
  const recovered = make();
  const closeAll = async () => {
    for (const item of managers) {
      try { await item.close(); } catch { /* targeted assertions own recovery */ }
    }
    for (const child of launcher.children) {
      if (child.exitCode === null && child.pid !== undefined) {
        try { process.kill(-child.pid, "SIGKILL"); } catch { /* already reaped */ }
      }
    }
    await rm(root, { recursive: true, force: true });
  };
  cleanup.push(closeAll);
  return { manager, recovered, store, launcher, cgroups, closeAll };
}

function expectGroupGone(pid: number | null): void {
  expect(pid).not.toBeNull();
  expect(() => process.kill(-pid!, 0)).toThrowError(expect.objectContaining({ code: "ESRCH" }));
}

describe("Studio preview process runner local process checks", () => {
  it("UNEXECUTED: a rejected real-runner kill is retried by the same manager", async () => {
    const h = await localHarness();
    const started = await h.manager.start(devRequest());
    h.cgroups.killError = new Error("transient cgroup kill failure");
    await expect(h.manager.stop({
      userId: UID, sessionId: SID, id: started.id,
    })).rejects.toMatchObject({ code: "cleanup_unproven" });
    expect(await h.store.facade().getLive()).toHaveLength(1);

    h.cgroups.killError = null;
    expect(await h.manager.stop({
      userId: UID, sessionId: SID, id: started.id,
    })).toMatchObject({ status: "stopped" });
    expectGroupGone(started.processId);
    expect(await h.store.facade().getLive()).toHaveLength(0);
  });

  it("UNEXECUTED: spawn-setup leaf-kill failure retains recoverable admission", async () => {
    const h = await localHarness({
      spawnError: new Error("launcher failed"),
      killError: new Error("leaf kill failed"),
    });
    await expect(h.manager.start(devRequest())).rejects.toMatchObject({
      code: "cleanup_unproven",
    });
    const live = await h.store.facade().getLive();
    expect(live).toHaveLength(1);
    expect(live[0]).toMatchObject({
      status: "stopping",
      failureCode: "cleanup_unproven",
      processGroupId: expect.stringContaining("preview-"),
    });
    expect(h.launcher.children).toHaveLength(0);
    h.cgroups.killError = null;
    await h.manager.close();
  });

  it("serves on a real private port and cleans stop and shutdown process trees", async () => {
    const h = await localHarness();
    const stopped = await h.manager.start(devRequest());
    expect(stopped.status).toBe("running");
    const response = await fetch(`http://127.0.0.1:${stopped.port}/`);
    expect(await response.text()).toBe("local-ok");
    const stoppedPid = stopped.processId;
    await h.manager.stop({ userId: UID, sessionId: SID, id: stopped.id });
    expectGroupGone(stoppedPid);

    const shutdown = await h.manager.start(devRequest());
    expect(shutdown.status).toBe("running");
    const shutdownPid = shutdown.processId;
    await h.manager.close();
    expectGroupGone(shutdownPid);
  }, 30_000);

  it("stale recovery kills only the recorded cgroup, never an unrelated reused PID", async () => {
    const h = await localHarness();
    const stale = await h.manager.start(devRequest());
    const stalePid = stale.processId;
    const unrelated = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
      detached: true,
      stdio: "ignore",
    });
    if (unrelated.pid === undefined) throw new Error("unrelated child did not start");
    const unrelatedPid = unrelated.pid;
    cleanup.push(() => {
      try { process.kill(-unrelatedPid, "SIGKILL"); } catch { /* already reaped */ }
    });

    // Simulate a replacement manager: it has no runtime handle, only durable
    // cgroup identity. An unrelated process is deliberately NOT in that group.
    const record = await h.store.get(stale.id);
    record.processId = unrelatedPid;
    await h.store.seed(record);
    await h.recovered.sweep();
    expectGroupGone(stalePid);
    expect(() => process.kill(unrelatedPid, 0)).not.toThrow();
    process.kill(-unrelatedPid, "SIGKILL");
  }, 30_000);
});
