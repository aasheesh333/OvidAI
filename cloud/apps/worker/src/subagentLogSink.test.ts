import { describe, expect, it } from "vitest";
import type { SandboxPort } from "@ovid/agent-core";

import {
  SANDBOX_SUBAGENT_LOG_DIR,
  createSandboxSubagentLogFactory,
} from "./subagentLogSink.js";

function fakeSandbox(): {
  port: SandboxPort;
  files: Map<string, string>;
  writes: Array<{ path: string; content: string }>;
  failWrites: { value: boolean };
} {
  const files = new Map<string, string>();
  const writes: Array<{ path: string; content: string }> = [];
  const failWrites = { value: false };
  const port: SandboxPort = {
    async exec() {
      return { exitCode: 0, stdout: "", stderr: "" };
    },
    async killCall() {},
    async readFile(_userId, path) {
      const value = files.get(path);
      if (value === undefined) throw new Error(`no such file: ${path}`);
      return value;
    },
    async writeFile(_userId, path, content) {
      if (failWrites.value) throw new Error("disk full");
      files.set(path, content);
      writes.push({ path, content });
    },
    async exists(_userId, path) {
      return files.has(path);
    },
    async listDir() {
      return [];
    },
    async jobStart() {
      return { jobId: "job-1" };
    },
    async jobOutput() {
      return { output: "", running: false, exitCode: 0 };
    },
    async jobList() {
      return [];
    },
    async jobKill() {},
  };
  return { port, files, writes, failWrites };
}

function lines(content: string): Array<Record<string, unknown>> {
  return content
    .split("\n")
    .filter((line) => line !== "")
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

describe("sandbox-backed subagent log", () => {
  it("writes the spec path INSIDE the sandbox workspace, not the worker host", async () => {
    const sbx = fakeSandbox();
    const factory = createSandboxSubagentLogFactory({
      sandbox: sbx.port,
      userId: "user-1",
    });

    const log = await factory({
      sessionId: "child-1",
      dir: SANDBOX_SUBAGENT_LOG_DIR,
      header: { parentSessionId: "parent-1", agentType: "general-purpose" },
    });
    await log.append({ type: "tool_started", name: "run_shell" });
    await log.append({ type: "tool_completed", name: "run_shell", ok: true });
    await log.close();

    expect(log.path).toBe("/workspace/.ovid/logs/subagent_child-1.log");
    expect(sbx.writes.length).toBeGreaterThan(0);
    // Every write goes through the SandboxPort at the jail-visible path; the
    // worker host path /workspace/... is never touched directly.
    for (const write of sbx.writes) {
      expect(write.path).toBe("/workspace/.ovid/logs/subagent_child-1.log");
    }

    const entries = lines(sbx.files.get(log.path)!);
    expect(entries[0]).toMatchObject({
      type: "subagent_log_started",
      sessionId: "child-1",
      parentSessionId: "parent-1",
      agentType: "general-purpose",
    });
    expect(entries.slice(1)).toEqual([
      expect.objectContaining({ type: "tool_started", name: "run_shell" }),
      expect.objectContaining({ type: "tool_completed", name: "run_shell", ok: true }),
    ]);
    expect(log.lastError()).toBeNull();
  });

  it("is append-only across a cold resume: the same child id extends, never truncates", async () => {
    const sbx = fakeSandbox();
    const factory = createSandboxSubagentLogFactory({
      sandbox: sbx.port,
      userId: "user-1",
    });

    const first = await factory({ sessionId: "child-2", dir: SANDBOX_SUBAGENT_LOG_DIR });
    await first.append({ type: "tool_completed", name: "read_file", content: "first" });
    await first.close();

    const second = await factory({ sessionId: "child-2", dir: SANDBOX_SUBAGENT_LOG_DIR });
    await second.append({ type: "subagent_result", status: "completed" });
    await second.close();

    const entries = lines(sbx.files.get(second.path)!);
    const headers = entries.filter((entry) => entry.type === "subagent_log_started");
    expect(headers).toHaveLength(2); // a new header per process, not an erased log
    expect(entries.some((entry) => entry.name === "read_file")).toBe(true);
    expect(entries.some((entry) => entry.type === "subagent_result")).toBe(true);
  });

  it("honours an injected log directory", async () => {
    const sbx = fakeSandbox();
    const factory = createSandboxSubagentLogFactory({
      sandbox: sbx.port,
      userId: "user-1",
    });
    const log = await factory({ sessionId: "child-3", dir: "/workspace/custom/logs" });
    await log.close();
    expect(log.path).toBe("/workspace/custom/logs/subagent_child-3.log");
  });

  it("rejects an id that could escape the log directory", async () => {
    const sbx = fakeSandbox();
    const factory = createSandboxSubagentLogFactory({
      sandbox: sbx.port,
      userId: "user-1",
    });
    await expect(factory({ sessionId: "../escape" })).rejects.toThrow(/unsafe subagent id/);
    await expect(factory({ sessionId: "a/b" })).rejects.toThrow(/unsafe subagent id/);
  });

  it("records a write failure instead of failing the child run", async () => {
    const sbx = fakeSandbox();
    sbx.failWrites.value = true;
    const factory = createSandboxSubagentLogFactory({
      sandbox: sbx.port,
      userId: "user-1",
    });

    const log = await factory({ sessionId: "child-4" });
    await expect(log.append({ type: "tool_started", name: "run_shell" })).resolves.toBeUndefined();
    await log.close();
    expect(log.lastError()).toBeInstanceOf(Error);
    expect(log.lastError()!.message).toContain("disk full");
  });
});
