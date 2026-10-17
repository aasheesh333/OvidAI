/**
 * Sandbox seam (P5 Task 16) — ungated unit tests.
 *
 * Two contracts are pinned here:
 * - `createUnavailableSandbox()` is the null-sandbox fallback: EVERY
 *   spawner/files call rejects `SandboxUnavailableError` with
 *   `code: "sandbox_unavailable"` (the router surfaces that as a clean tool
 *   error, never a crash).
 * - `createSandboxSeam({manager})` adapts P2's landed SandboxManager onto
 *   @ovid/mcp's SandboxSpawner/SandboxFiles, absorbing the
 *   `{workspacesRoot}/{uid}/workspace` layout through `handle.workspaceDir`
 *   (jail `/workspace/...` → host path) and mapping exec/spawn onto the
 *   handle's one-shot/long-running primitives.
 */

import { mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import type { SandboxHandle, SandboxManager } from "@ovid/sandbox";
import {
  SandboxUnavailableError,
  createSandboxSeam,
  createUnavailableSandbox,
} from "./sandboxSeam.js";

const scratch: string[] = [];

async function tempDir(prefix: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), prefix));
  scratch.push(dir);
  return dir;
}

afterAll(async () => {
  await Promise.all(scratch.map((d) => rm(d, { recursive: true, force: true })));
});

/** Every public method of the fallback pair must reject with the same code. */
async function expectUnavailable(fn: () => Promise<unknown>): Promise<void> {
  let caught: unknown;
  try {
    await fn();
  } catch (err) {
    caught = err;
  }
  expect(caught).toBeInstanceOf(SandboxUnavailableError);
  expect((caught as SandboxUnavailableError).code).toBe("sandbox_unavailable");
}

describe("createUnavailableSandbox", () => {
  it("every spawner/files call rejects SandboxUnavailableError(code sandbox_unavailable)", async () => {
    const sandbox = createUnavailableSandbox();

    await expectUnavailable(() =>
      sandbox.spawner.spawn("user-1", { command: "node", args: ["server.js"] }),
    );
    await expectUnavailable(() => sandbox.files.read("user-1", "/workspace/a.txt"));
    await expectUnavailable(() => sandbox.files.write("user-1", "/workspace/a.txt", "x"));
    await expectUnavailable(() => sandbox.files.list("user-1", "/workspace"));
    await expectUnavailable(() => sandbox.files.stat("user-1", "/workspace/a.txt"));
    await expectUnavailable(() => sandbox.files.remove("user-1", "/workspace/a.txt"));
    await expectUnavailable(() => sandbox.files.uploadDir("user-1", "/tmp/local", "/workspace/x"));
    await expectUnavailable(() =>
      sandbox.files.exec("user-1", { command: "npm", args: ["install"] }),
    );
  });
});

describe("createSandboxSeam (P2 adaptation)", () => {
  it("maps spawner/files/exec onto the manager handle and the workspace layout", async () => {
    const workspaceDir = await tempDir("ovid-seam-workspace-");
    const uid = typeof process.getuid === "function" ? process.getuid() : 1000;

    const spawnCalls: Array<{
      argv: string[];
      cwd?: string;
      env?: Record<string, string>;
    }> = [];
    const execCalls: Array<{ argv: string[]; cwd?: string; env?: Record<string, string> }> = [];
    const attachCalls: Array<{ userId: string; tier?: "free" | "pro" }> = [];

    const proc = {
      id: "proc-1",
      pid: 4242,
      writeLine: () => {},
      onStdoutLine: () => {},
      onExit: () => {},
      kill: async () => {},
    };

    const handle = {
      userId: "user-1",
      uid,
      workspaceDir,
      homeDir: join(workspaceDir, "..", ".home"),
      jailWorkspaceDir: "/workspace",
      exec: async (req: { argv?: string[]; cwd?: string; env?: Record<string, string> }) => {
        execCalls.push({ argv: req.argv ?? [], cwd: req.cwd, env: req.env });
        return {
          exitCode: 0,
          stdout: "ok",
          stderr: "",
          timedOut: false,
          truncated: false,
          blocked: false,
          refusal: null,
        };
      },
      createPty: async () => {
        throw new Error("unused");
      },
      getPty: () => undefined,
      jobs: {},
      spawnProcess: async (req: {
        argv: string[];
        cwd?: string;
        env?: Record<string, string>;
      }) => {
        spawnCalls.push(req);
        return proc;
      },
      destroy: async () => {},
    } as unknown as SandboxHandle;

    const manager = {
      attach: async (userId: string, opts?: { tier?: "free" | "pro" }) => {
        attachCalls.push({ userId, tier: opts?.tier });
        return handle;
      },
      get: () => handle,
      destroy: async () => {},
      list: () => [],
      activeCount: () => 1,
      workspaceDir: async () => workspaceDir,
      recover: async () => {},
      close: async () => {},
    } as unknown as SandboxManager;

    const seam = createSandboxSeam({
      manager,
      tierFor: (id) => (id === "user-1" ? "pro" : "free"),
    });

    // -- spawner ---------------------------------------------------------
    const spawned = await seam.spawner.spawn("user-1", {
      command: "node",
      args: ["server.js", "--stdio"],
      cwd: "/workspace",
      env: { TOKEN: "t" },
    });
    expect(spawned.pid).toBe(4242);
    expect(spawnCalls).toEqual([
      { argv: ["node", "server.js", "--stdio"], cwd: "/workspace", env: { TOKEN: "t" } },
    ]);
    expect(attachCalls).toEqual([{ userId: "user-1", tier: "pro" }]);

    // -- files (jail /workspace → handle.workspaceDir) -------------------
    await seam.files.write("user-1", "/workspace/notes/a.txt", "hello");
    expect(await readFile(join(workspaceDir, "notes", "a.txt"), "utf8")).toBe("hello");

    const read = await seam.files.read("user-1", "/workspace/notes/a.txt");
    expect(read).toEqual({ content: "hello", bytes: 5 });
    expect(await seam.files.read("user-1", "/workspace/missing.txt")).toBeNull();

    const info = await seam.files.stat("user-1", "/workspace/notes/a.txt");
    expect(info?.type).toBe("file");
    expect(info?.size).toBe(5);

    const listing = await seam.files.list("user-1", "/workspace/notes");
    expect(listing.map((e) => e.name)).toContain("a.txt");

    await seam.files.remove("user-1", "/workspace/notes/a.txt");
    expect(await seam.files.stat("user-1", "/workspace/notes/a.txt")).toBeNull();

    // -- uploadDir (install staging → jail path) -------------------------
    const local = await tempDir("ovid-seam-local-");
    await writeFile(join(local, "plugin.json"), "{}", "utf8");
    await seam.files.uploadDir("user-1", local, "/workspace/.ovid/plugins/acme/demo");
    expect(
      await readFile(
        join(workspaceDir, ".ovid", "plugins", "acme", "demo", "plugin.json"),
        "utf8",
      ),
    ).toBe("{}");

    // -- exec ------------------------------------------------------------
    const exec = await seam.files.exec("user-1", {
      command: "mv",
      args: ["/workspace/a", "/workspace/b"],
      timeoutMs: 1000,
    });
    expect(exec).toEqual({ exitCode: 0, stdout: "ok", stderr: "" });
    expect(execCalls[0]?.argv).toEqual(["mv", "/workspace/a", "/workspace/b"]);

    // -- confinement -----------------------------------------------------
    await expect(seam.files.read("user-1", "/etc/passwd")).rejects.toThrow();
    expect((await stat(join(workspaceDir, "notes"))).isDirectory()).toBe(true);
  });

  it("maps a workspace-relative cwd onto /workspace (M8, same rule as sandboxAdapter.jailCwd)", async () => {
    const workspaceDir = await tempDir("ovid-seam-cwd-");
    const spawnCalls: Array<{ cwd?: string }> = [];
    const execCalls: Array<{ cwd?: string }> = [];

    const handle = {
      userId: "user-1",
      uid: typeof process.getuid === "function" ? process.getuid() : 1000,
      workspaceDir,
      homeDir: join(workspaceDir, "..", ".home"),
      jailWorkspaceDir: "/workspace",
      exec: async (req: { cwd?: string }) => {
        execCalls.push({ cwd: req.cwd });
        return {
          exitCode: 0,
          stdout: "",
          stderr: "",
          timedOut: false,
          truncated: false,
          blocked: false,
          refusal: null,
        };
      },
      spawnProcess: async (req: { cwd?: string }) => {
        spawnCalls.push({ cwd: req.cwd });
        return {
          id: "proc-1",
          pid: 1,
          writeLine: () => {},
          onStdoutLine: () => {},
          onExit: () => {},
          kill: async () => {},
        };
      },
      createPty: async () => {
        throw new Error("unused");
      },
      getPty: () => undefined,
      jobs: {},
      destroy: async () => {},
    } as unknown as SandboxHandle;

    const manager = {
      attach: async () => handle,
      get: () => handle,
      destroy: async () => {},
      list: () => [],
      activeCount: () => 1,
      workspaceDir: async () => workspaceDir,
      recover: async () => {},
      close: async () => {},
    } as unknown as SandboxManager;

    const seam = createSandboxSeam({ manager });
    await seam.spawner.spawn("user-1", { command: "node", args: ["s.js"], cwd: "notes/sub" });
    await seam.spawner.spawn("user-1", { command: "node", args: ["s.js"], cwd: "/workspace/abs" });
    await seam.spawner.spawn("user-1", { command: "node", args: ["s.js"] });
    await seam.files.exec("user-1", { command: "ls", args: [], cwd: "notes" });
    await seam.files.exec("user-1", { command: "ls", args: [] });

    expect(spawnCalls).toEqual([
      { cwd: "/workspace/notes/sub" },
      { cwd: "/workspace/abs" },
      { cwd: undefined },
    ]);
    expect(execCalls).toEqual([{ cwd: "/workspace/notes" }, { cwd: undefined }]);
  });

  it("remove refuses the workspace root (C1 defense-in-depth) and still deletes nested paths", async () => {
    const workspaceDir = await tempDir("ovid-seam-remove-");
    await writeFile(join(workspaceDir, "keep.txt"), "keep", "utf8");
    const handle = {
      userId: "user-1",
      uid: typeof process.getuid === "function" ? process.getuid() : 1000,
      workspaceDir,
      homeDir: join(workspaceDir, "..", ".home"),
      jailWorkspaceDir: "/workspace",
      exec: async () => ({}),
      spawnProcess: async () => ({}),
      createPty: async () => {
        throw new Error("unused");
      },
      getPty: () => undefined,
      jobs: {},
      destroy: async () => {},
    } as unknown as SandboxHandle;
    const manager = {
      attach: async () => handle,
      get: () => handle,
      destroy: async () => {},
      list: () => [],
      activeCount: () => 1,
      workspaceDir: async () => workspaceDir,
      recover: async () => {},
      close: async () => {},
    } as unknown as SandboxManager;
    const seam = createSandboxSeam({ manager });

    await expect(seam.files.remove("user-1", "/workspace")).rejects.toThrow(
      /workspace root/,
    );
    await expect(seam.files.remove("user-1", "/workspace/")).rejects.toThrow(
      /workspace root/,
    );
    // Nothing was removed.
    expect(await readFile(join(workspaceDir, "keep.txt"), "utf8")).toBe("keep");

    // A legitimate nested path still deletes.
    await writeFile(join(workspaceDir, "tmp.txt"), "x", "utf8");
    await seam.files.remove("user-1", "/workspace/tmp.txt");
    expect(await seam.files.stat("user-1", "/workspace/tmp.txt")).toBeNull();
  });

  it("list skips symlinks instead of reporting them as directories (M9)", async () => {
    const workspaceDir = await tempDir("ovid-seam-symlink-");
    await writeFile(join(workspaceDir, "real.txt"), "x", "utf8");
    await symlink(workspaceDir, join(workspaceDir, "loop"));
    const handle = {
      userId: "user-1",
      uid: typeof process.getuid === "function" ? process.getuid() : 1000,
      workspaceDir,
      homeDir: join(workspaceDir, "..", ".home"),
      jailWorkspaceDir: "/workspace",
      exec: async () => ({}),
      spawnProcess: async () => ({}),
      createPty: async () => {
        throw new Error("unused");
      },
      getPty: () => undefined,
      jobs: {},
      destroy: async () => {},
    } as unknown as SandboxHandle;
    const manager = {
      attach: async () => handle,
      get: () => handle,
      destroy: async () => {},
      list: () => [],
      activeCount: () => 1,
      workspaceDir: async () => workspaceDir,
      recover: async () => {},
      close: async () => {},
    } as unknown as SandboxManager;
    const seam = createSandboxSeam({ manager });

    const listing = await seam.files.list("user-1", "/workspace");
    expect(listing.map((e) => e.name)).toEqual(["real.txt"]);
    expect(listing.some((e) => e.name === "loop")).toBe(false);
  });
});
