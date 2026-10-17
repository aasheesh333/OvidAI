import { afterEach, describe, expect, it, vi } from "vitest";

import type { SandboxPort } from "../ports.js";
import type { ToolResult } from "../types.js";
import {
  SPILL_DEFAULT_CAP,
  TOOL_TIMEOUT_MESSAGE,
  spillToolOutput,
  toolOutputCapFor,
  withToolTimeout,
} from "./spill.js";

function fakeSandbox() {
  const writes: Array<{ userId: string; path: string; content: string }> = [];
  const kills: Array<[string, string]> = [];
  const sandbox: SandboxPort = {
    exec: async () => ({ exitCode: 0, stdout: "", stderr: "" }),
    killCall: async (userId, callKey) => {
      kills.push([userId, callKey]);
    },
    readFile: async () => "",
    writeFile: async (userId, path, content) => {
      writes.push({ userId, path, content });
    },
    exists: async () => false,
    listDir: async () => [],
    jobStart: async () => ({ jobId: "job-1" }),
    jobOutput: async () => ({ output: "", running: false, exitCode: null }),
    jobList: async () => [],
    jobKill: async () => {},
  };
  return { sandbox, writes, kills };
}

afterEach(() => {
  vi.useRealTimers();
});

describe("toolOutputCapFor / SPILL_DEFAULT_CAP", () => {
  it("the cap is 6000 for everything (device_read's 24000 died with D5)", () => {
    expect(SPILL_DEFAULT_CAP).toBe(6000);
    expect(toolOutputCapFor("run_shell")).toBe(6000);
    expect(toolOutputCapFor("fs_grep")).toBe(6000);
    expect(toolOutputCapFor("device_read")).toBe(6000);
  });
});

describe("spillToolOutput", () => {
  it("returns text under the cap verbatim with zero writes", async () => {
    const { sandbox, writes } = fakeSandbox();
    const out = await spillToolOutput(
      { sandbox, userId: "u1", workspaceRelDir: "" },
      "run_shell",
      "short output",
      100,
    );
    expect(out).toBe("short output");
    expect(writes).toEqual([]);
  });

  it("persists the FULL overflow text and returns head + exact notice + tail", async () => {
    const { sandbox, writes } = fakeSandbox();
    const big = Array.from({ length: 300 }, (_, i) => `line-${i} ${"x".repeat(50)}`).join("\n");
    const out = await spillToolOutput(
      { sandbox, userId: "u1", workspaceRelDir: "" },
      "run_shell",
      big,
      1000,
    );

    // one write, under .spill/, with the FULL text
    expect(writes).toHaveLength(1);
    expect(writes[0].userId).toBe("u1");
    expect(writes[0].path).toMatch(/^\.spill\/\d+\.txt$/);
    expect(writes[0].content).toBe(big);

    // the result is the exact head/marker/tail construction
    const relPath = writes[0].path;
    const head = big.slice(0, 500);
    const tail = big.slice(big.length - 500);
    const omitted = big.length - 1000;
    const locator =
      `run_shell: \`sed -n "L,LP" ${relPath}\` for a line range, ` +
      `\`grep -n "<pattern>" ${relPath}\` to find lines`;
    expect(out).toBe(
      `${head}\n\n[…${omitted} characters omitted — full output saved to ${relPath}. ${locator}…]\n\n${tail}`,
    );
  });

  it("names the spill file relative to the session workspace when workspaceRelDir is set", async () => {
    const { sandbox, writes } = fakeSandbox();
    const big = "y".repeat(2000);
    const out = await spillToolOutput(
      { sandbox, userId: "u1", workspaceRelDir: "sessions/s1" },
      "file_read",
      big,
      500,
    );
    expect(writes).toHaveLength(1);
    expect(writes[0].path).toMatch(/^sessions\/s1\/\.spill\/\d+\.txt$/);
    // the locator still speaks session-workspace-relative
    expect(out).toContain("full output saved to .spill/");
    expect(out).toContain("fs_edit view");
    expect(out).toContain("(path .spill/");
  });

  it("fs_grep/fs_glob get the narrower-pattern locator, run_shell gets the sed/grep one", async () => {
    const { sandbox, writes } = fakeSandbox();
    const big = "y".repeat(2000);
    const grepOut = await spillToolOutput(
      { sandbox, userId: "u1", workspaceRelDir: "" },
      "fs_grep",
      big,
      500,
    );
    expect(grepOut).toContain("narrower `pattern`");
    expect(grepOut).toContain("include");
    expect(grepOut).not.toContain("sed -n");

    const globOut = await spillToolOutput(
      { sandbox, userId: "u2", workspaceRelDir: "" },
      "fs_glob",
      big,
      500,
    );
    expect(globOut).toContain("narrower `pattern`");

    const shellOut = await spillToolOutput(
      { sandbox, userId: "u3", workspaceRelDir: "" },
      "run_shell",
      big,
      500,
    );
    expect(shellOut).toContain("sed -n");
    expect(shellOut).not.toContain("narrower");
    expect(writes).toHaveLength(3);
  });

  it("uses the default cap of 6000 when cap is omitted", async () => {
    const { sandbox, writes } = fakeSandbox();
    const exactly = "z".repeat(6000);
    expect(await spillToolOutput({ sandbox, userId: "u1", workspaceRelDir: "" }, "run_shell", exactly)).toBe(exactly);
    expect(writes).toEqual([]);
    const over = "z".repeat(6001);
    const out = await spillToolOutput({ sandbox, userId: "u1", workspaceRelDir: "" }, "run_shell", over);
    expect(out).toContain("1 characters omitted");
    expect(writes).toHaveLength(1);
  });
});

describe("TOOL_TIMEOUT_MESSAGE", () => {
  it("is the exact Dart copy", () => {
    expect(TOOL_TIMEOUT_MESSAGE("run_shell", 600)).toBe(
      'Error: tool "run_shell" timed out after 600s and its processes were KILLED. ' +
        "It may have partially completed — check the current state " +
        "(read the file, `git status`) before doing anything else, and do NOT re-run it blindly.",
    );
  });
});

describe("withToolTimeout", () => {
  it("resolves with the wrapped promise when it beats the clock", async () => {
    const { sandbox, kills } = fakeSandbox();
    const res = await withToolTimeout(Promise.resolve({ content: "done" }), {
      timeoutMs: 60_000,
      callKey: "toolcall-1",
      toolName: "run_shell",
      onKill: () => sandbox.killCall("u1", "toolcall-1"),
    });
    expect(res).toEqual({ content: "done" });
    expect(kills).toEqual([]);
  });

  it("kills by callKey and resolves with the pinned KILLED message", async () => {
    vi.useFakeTimers();
    const { sandbox, kills } = fakeSandbox();
    const never = new Promise<ToolResult>(() => {});
    const wrapped = withToolTimeout(never, {
      timeoutMs: 600_000,
      callKey: "toolcall-7",
      toolName: "run_shell",
      onKill: () => sandbox.killCall("u1", "toolcall-7"),
    });
    await vi.advanceTimersByTimeAsync(600_000);
    const res = await wrapped;
    expect(kills).toEqual([["u1", "toolcall-7"]]);
    expect(res.content).toBe(TOOL_TIMEOUT_MESSAGE("run_shell", 600));
    expect(res.isError).toBe(true);
  });

  it("a late resolution after the timeout never reaches the caller", async () => {
    vi.useFakeTimers();
    const { sandbox, kills } = fakeSandbox();
    let lateResolve!: (r: ToolResult) => void;
    const never = new Promise<ToolResult>((resolve) => {
      lateResolve = resolve;
    });
    const wrapped = withToolTimeout(never, {
      timeoutMs: 1_000,
      callKey: "toolcall-8",
      toolName: "run_code",
      onKill: () => sandbox.killCall("u1", "toolcall-8"),
    });
    await vi.advanceTimersByTimeAsync(1_000);
    const res = await wrapped;
    lateResolve({ content: "late output must be discarded" });
    await Promise.resolve();
    expect(res.content).toBe(TOOL_TIMEOUT_MESSAGE("run_code", 1));
    expect(kills).toEqual([["u1", "toolcall-8"]]);
  });

  it("an onKill failure must not mask the timeout result", async () => {
    vi.useFakeTimers();
    const never = new Promise<ToolResult>(() => {});
    const wrapped = withToolTimeout(never, {
      timeoutMs: 1_000,
      callKey: "toolcall-9",
      toolName: "run_shell",
      onKill: async () => {
        throw new Error("kill channel down");
      },
    });
    await vi.advanceTimersByTimeAsync(1_000);
    const res = await wrapped;
    expect(res.content).toBe(TOOL_TIMEOUT_MESSAGE("run_shell", 1));
    expect(res.isError).toBe(true);
  });

  it("propagates a pre-timeout rejection (infrastructure errors stay loud)", async () => {
    const { sandbox } = fakeSandbox();
    await expect(
      withToolTimeout(Promise.reject(new Error("boom")), {
        timeoutMs: 60_000,
        callKey: "toolcall-10",
        toolName: "run_shell",
        onKill: () => sandbox.killCall("u1", "toolcall-10"),
      }),
    ).rejects.toThrow("boom");
  });
});
