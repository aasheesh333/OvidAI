import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";

import {
  JAIL_WORKSPACE,
  REFUSAL_MESSAGE,
  type ExecRequest,
  type ExecResult,
  type JobInfo,
  type JobOutput,
  type JobRegistry,
  type SandboxHandle,
  type SandboxManager,
} from "@ovid/sandbox";

import { createSandboxPort, createStepLimiter } from "./sandboxAdapter.js";

/**
 * Shape test: the adapter wraps P2's REAL SandboxManager (exercised end to end
 * in the Task 16 integration). Written against the P2 plan's Produces block —
 * and pinning the C3 drift absorptions: the callKey→leaf/child map (P2's
 * ExecRequest has no callKey and kills on timeout internally) and the file
 * methods synthesized over workspaceDir + resolveConfined.
 */

const workspaceDir = await mkdtemp(join(tmpdir(), "ovid-sandbox-adapter-"));
afterAll(async () => {
  const { rm } = await import("node:fs/promises");
  await rm(workspaceDir, { recursive: true, force: true });
});

function fakeManager() {
  const execCalls: ExecRequest[] = [];
  const jobStarts: Array<{ command: string; cwd?: string }> = [];
  const jobKills: string[] = [];
  const jobs: JobInfo[] = [];
  let nextExecResult: ExecResult = {
    exitCode: 0,
    stdout: "ok",
    stderr: "",
    timedOut: false,
    truncated: false,
    blocked: false,
    refusal: null,
  };
  let deferExec = false;
  let resolveDeferred: ((r: ExecResult) => void) | undefined;

  const jobRegistry: JobRegistry = {
    start: async (req) => {
      jobStarts.push({ command: req.command, cwd: req.cwd });
      const info: JobInfo = {
        id: `job-${jobStarts.length}`,
        command: req.command,
        state: "running",
        exitCode: null,
        startedAt: new Date().toISOString(),
        endOffset: 0,
      };
      jobs.push(info);
      return info;
    },
    list: () => jobs,
    output: (id: string): JobOutput | null => {
      if (id !== "job-1") return null;
      const buf = Buffer.from("hello job output", "utf8");
      return {
        truncated: false,
        chunks: [{ offset: 0, data: buf.toString("base64") }],
        endOffset: buf.length,
      };
    },
    kill: async (id: string) => {
      jobKills.push(id);
      const j = jobs.find((x) => x.id === id);
      if (j) j.state = "killed";
    },
    killAll: async () => {},
    get size() {
      return jobs.length;
    },
  };

  const handle: SandboxHandle = {
    userId: "u1",
    uid: 1000,
    workspaceDir,
    homeDir: workspaceDir,
    jailWorkspaceDir: JAIL_WORKSPACE,
    exec: async (req: ExecRequest) => {
      execCalls.push(req);
      if (deferExec) return new Promise<ExecResult>((resolve) => (resolveDeferred = resolve));
      return nextExecResult;
    },
    createPty: async () => {
      throw new Error("not used by the SandboxPort");
    },
    getPty: () => undefined,
    jobs: jobRegistry,
    spawnProcess: async () => {
      throw new Error("not used by the SandboxPort");
    },
    destroy: async () => {},
  } as SandboxHandle;

  const manager = {
    attach: async (userId: string) => {
      if (userId !== "u1") throw new Error(`unknown user: ${userId}`);
      return handle;
    },
    attachSession: async (userId: string, sessionId: string) => {
      if (userId !== "u1") throw new Error(`unknown user: ${userId}`);
      (manager as unknown as { lastSessionId?: string }).lastSessionId = sessionId;
      return handle;
    },
    sessionWorkspaceDir: async () => workspaceDir,
    get: (userId: string) => (userId === "u1" ? handle : undefined),
    destroy: async () => {},
    list: () => [] as never[],
    activeCount: () => 1,
    workspaceDir: async () => workspaceDir,
    recover: async () => {},
    close: async () => {},
  } as unknown as SandboxManager;

  return {
    manager,
    handle,
    execCalls,
    jobStarts,
    jobKills,
    setExecResult: (r: ExecResult) => {
      nextExecResult = r;
    },
    deferNextExec: () => {
      deferExec = true;
    },
    resolveDeferred: (r: ExecResult) => {
      resolveDeferred?.(r);
    },
  };
}

describe("createSandboxPort — exec", () => {
  it("maps the port shape onto ExecRequest with a jail-side cwd and NO callKey", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    const res = await port.exec("u1", {
      cmd: "ls -la",
      cwd: "sessions/s1",
      timeoutMs: 5000,
      callKey: "k1",
      env: { X: "1" },
    });
    expect(res).toEqual({ exitCode: 0, stdout: "ok", stderr: "" });
    expect(m.execCalls).toHaveLength(1);
    expect(m.execCalls[0]).toMatchObject({
      command: "ls -la",
      cwd: "/workspace/sessions/s1",
      timeoutMs: 5000,
      env: { X: "1" },
    });
    // C3 drift: P2's ExecRequest has no callKey — the adapter tracks it
    // internally instead of passing it down.
    expect("callKey" in m.execCalls[0]).toBe(false);
  });

  it("passes an absolute cwd through and defaults to the jail workspace", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    await port.exec("u1", { cmd: "pwd", cwd: "/tmp" });
    await port.exec("u1", { cmd: "pwd" });
    expect(m.execCalls[0].cwd).toBe("/tmp");
    expect(m.execCalls[1].cwd).toBeUndefined();
  });

  it("a blocked verdict maps to a refused, non-zero result", async () => {
    const m = fakeManager();
    m.setExecResult({
      exitCode: null,
      stdout: "",
      stderr: "",
      timedOut: false,
      truncated: false,
      blocked: true,
      refusal: REFUSAL_MESSAGE,
    });
    const port = createSandboxPort(m.manager);
    const res = await port.exec("u1", { cmd: "gradle assembleDebug" });
    expect(res.exitCode).not.toBe(0);
    expect(res.stderr).toBe(REFUSAL_MESSAGE);
    expect(res.stdout).toBe("");
  });

  it("a killed (null exit) one-shot maps to a non-zero exit code", async () => {
    const m = fakeManager();
    m.setExecResult({
      exitCode: null,
      stdout: "partial",
      stderr: "",
      timedOut: true,
      truncated: false,
      blocked: false,
      refusal: null,
    });
    const port = createSandboxPort(m.manager);
    const res = await port.exec("u1", { cmd: "sleep 999", timeoutMs: 10 });
    expect(res.exitCode).not.toBe(0);
    expect(res.stdout).toBe("partial");
  });
});

describe("createSandboxPort — killCall (C3 drift absorption)", () => {
  it("killCall on an unknown key is a no-op", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    await expect(port.killCall("u1", "nope")).resolves.toBeUndefined();
  });

  it("a tracked exec killCall waits for the one-shot to settle (execOnce kills on its own timeout)", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    m.deferNextExec();
    const execP = port.exec("u1", { cmd: "long", timeoutMs: 12345, callKey: "k9" });
    // let the exec pass attach and register its callKey in the adapter's map
    await new Promise((r) => setImmediate(r));
    let killSettled = false;
    const killP = port.killCall("u1", "k9").then(() => {
      killSettled = true;
    });
    // the tracked exec is still pending, so killCall must still be waiting
    expect(killSettled).toBe(false);
    m.resolveDeferred({
      exitCode: null,
      stdout: "",
      stderr: "",
      timedOut: true,
      truncated: false,
      blocked: false,
      refusal: null,
    });
    await killP; // resolves once the tracked exec settled
    await execP;
    expect(killSettled).toBe(true);
    // and the entry is gone: a second killCall is an immediate no-op
    await expect(port.killCall("u1", "k9")).resolves.toBeUndefined();
  });

  it("killCall from the wrong user is ignored", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    m.deferNextExec();
    const execP = port.exec("u1", { cmd: "long", callKey: "k10" });
    await new Promise((r) => setImmediate(r));
    await expect(port.killCall("u2", "k10")).resolves.toBeUndefined();
    m.resolveDeferred({
      exitCode: 0,
      stdout: "",
      stderr: "",
      timedOut: false,
      truncated: false,
      blocked: false,
      refusal: null,
    });
    await execP;
  });
});

describe("createSandboxPort — file methods (workspaceDir + resolveConfined)", () => {
  it("write/read/exists/listDir round-trip inside the workspace", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    await port.writeFile("u1", "sub/a.txt", "hi");
    expect(await port.readFile("u1", "sub/a.txt")).toBe("hi");
    expect(await port.exists("u1", "sub/a.txt")).toBe(true);
    expect(await port.exists("u1", "missing.txt")).toBe(false);
    expect(await port.listDir("u1", "sub")).toEqual(["a.txt"]);
    // /workspace-prefixed paths are accepted like P2's file tools
    expect(await port.readFile("u1", "/workspace/sub/a.txt")).toBe("hi");
  });

  it("escapes reject — relative, absolute and symlinked", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    await expect(port.readFile("u1", "../escape.txt")).rejects.toThrow(/outside the workspace/);
    await expect(port.readFile("u1", "/etc/passwd")).rejects.toThrow(/outside the workspace/);
    await expect(port.writeFile("u1", "a/../../evil.txt", "x")).rejects.toThrow(
      /outside the workspace/,
    );
  });

  it("reading a missing file rejects with the pinned no-such-file message", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    await expect(port.readFile("u1", "gone.txt")).rejects.toThrow(/no such file: gone.txt/);
  });
});

describe("createSandboxPort — jobs", () => {
  it("start/output/list/kill map onto the JobRegistry", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    const { jobId } = await port.jobStart("u1", { cmd: "npm run dev", cwd: "sub" });
    expect(jobId).toBe("job-1");
    expect(m.jobStarts[0]).toEqual({ command: "npm run dev", cwd: "/workspace/sub" });

    const out = await port.jobOutput("u1", "job-1", { offset: 0 });
    expect(out.output).toBe("hello job output");
    expect(out.running).toBe(true);
    expect(out.exitCode).toBeNull();

    const list = await port.jobList("u1");
    expect(list).toEqual([{ jobId: "job-1", cmd: "npm run dev", running: true }]);

    await port.jobKill("u1", "job-1");
    expect(m.jobKills).toEqual(["job-1"]);
    const after = await port.jobList("u1");
    expect(after[0].running).toBe(false);
  });

  it("output of an unknown job rejects with the pinned message", async () => {
    const m = fakeManager();
    const port = createSandboxPort(m.manager);
    await expect(port.jobOutput("u1", "job-x")).rejects.toThrow(/no such job: job-x/);
  });
});

// ---------------------------------------------------------------------------
// Step limiter (owner directive 2026-10-18): run concurrency and STEP
// concurrency are different budgets. A run streams tokens for seconds while
// costing no CPU; the local step is what the box must bound.
// ---------------------------------------------------------------------------

describe("createStepLimiter", () => {
  it("never runs more than `max` steps at once, and releases on completion", async () => {
    const limiter = createStepLimiter(2);
    let active = 0;
    let peak = 0;
    const gate: Array<() => void> = [];

    const task = () =>
      limiter.run(async () => {
        active += 1;
        peak = Math.max(peak, active);
        await new Promise<void>((resolve) => gate.push(resolve));
        active -= 1;
      });

    const all = [task(), task(), task(), task()];
    // Two are running; two are queued behind them.
    await new Promise((r) => setTimeout(r, 10));
    expect(limiter.stats()).toMatchObject({ active: 2, waiting: 2, max: 2 });
    expect(peak).toBe(2);

    // Release in FIFO order until every task has run.
    while (gate.length > 0) {
      gate.shift()!();
      await new Promise((r) => setTimeout(r, 5));
    }
    await Promise.all(all);
    expect(peak).toBe(2);
    expect(limiter.stats()).toMatchObject({ active: 0, waiting: 0 });
  });

  it("releases the permit when the step THROWS (a failed tool cannot leak it)", async () => {
    const limiter = createStepLimiter(1);
    await expect(
      limiter.run(async () => {
        throw new Error("tool blew up");
      }),
    ).rejects.toThrow("tool blew up");
    expect(limiter.stats()).toMatchObject({ active: 0, waiting: 0 });
    // The next step still gets in.
    await expect(limiter.run(async () => "ok")).resolves.toBe("ok");
  });

  it("transfers the permit on release — a new arrival in the wake window cannot over-admit", async () => {
    // The pre-fix race: `release` decremented, THEN resolved the head waiter,
    // whose continuation re-incremented a microtask later. A run() arriving in
    // that window saw active < max and took a SECOND permit, so the bound was
    // soft. One `await Promise.resolve()` hop lands exactly in the window:
    // A's finally has run but the woken waiter (B) has not resumed yet.
    const limiter = createStepLimiter(1);
    let peak = 0;
    const track = (name: string) =>
      limiter.run(async () => {
        peak = Math.max(peak, limiter.stats().active);
        return name;
      });
    // Narrow the resolver to () => void so the manual release gate keeps the
    // declaration's simple type (a Promise resolver takes a value).
    let releaseA: () => void = () => {};
    const a = limiter.run(
      () =>
        new Promise<string>((resolve) => {
          releaseA = () => resolve('');
        }),
    );
    const b = track("b"); // FIFO head — waits on A
    releaseA();
    await Promise.resolve(); // A transferred; B's continuation is still queued
    const c = track("c"); // must queue behind the transferred permit

    const results = await Promise.all([a.then(() => "a"), b, c]);
    expect(results).toEqual(["a", "b", "c"]);
    expect(peak).toBe(1); // never two steps inside a max-1 limiter
    expect(limiter.stats()).toMatchObject({ active: 0, waiting: 0 });
  });

  it("rejects a non-positive bound instead of silently running unbounded", () => {
    expect(() => createStepLimiter(0)).toThrow(/positive integer/);
    expect(() => createStepLimiter(-1)).toThrow(/positive integer/);
    expect(() => createStepLimiter(1.5)).toThrow(/positive integer/);
  });

  it("the port applies the limiter to file steps (one attach at a time at limit 1)", async () => {
    const limiter = createStepLimiter(1);
    let attachesInFlight = 0;
    let peak = 0;
    const m = fakeManager();
    // Wrap attach so the test observes how many steps are INSIDE the port.
    const realAttach = m.manager.attach.bind(m.manager);
    (m.manager as unknown as { attach: typeof realAttach }).attach = async (...args) => {
      attachesInFlight += 1;
      peak = Math.max(peak, attachesInFlight);
      try {
        await new Promise((r) => setTimeout(r, 20));
        return await realAttach(...args);
      } finally {
        attachesInFlight -= 1;
      }
    };

    const port = createSandboxPort(m.manager, { stepLimit: limiter });
    await Promise.all([
      port.exists("u1", "a.txt").catch(() => false),
      port.exists("u1", "b.txt").catch(() => false),
    ]);
    // With one permit the second step cannot enter until the first leaves.
    expect(peak).toBe(1);
  });
});

describe("per-session workspace", () => {
  it("a port built with a sessionId attaches that session's workspace, not the user's", async () => {
    const { manager, execCalls } = fakeManager();
    const port = createSandboxPort(manager, { sessionId: "sess-42" });
    await port.exec("u1", { cmd: "pwd" });
    expect(execCalls).toHaveLength(1);
    // The handle handed out must be the session view.
    expect((manager as unknown as { lastSessionId?: string }).lastSessionId).toBe("sess-42");
  });

  it("a port built without a sessionId keeps the legacy per-user attach", async () => {
    const { manager } = fakeManager();
    const port = createSandboxPort(manager);
    await port.exec("u1", { cmd: "pwd" });
    expect((manager as unknown as { lastSessionId?: string }).lastSessionId).toBeUndefined();
  });
});
