// Spec Screen 2: "Both the User (via UI dropdown) and the Ovid Agent
// (autonomously during tasks) can switch branches or repositories at any
// time."
//
// The agent could clone into a repo and push, but it had no way to CHANGE the
// branch of a working tree it was already in — so "switch branch autonomously"
// existed only as an unstaged `git checkout` the model had to guess at, with
// no dirty-tree guard and no approval.

import { describe, expect, it } from "vitest";

import type { ApprovalDecision, ApprovalGate, ApprovalRequest, SandboxPort } from "../ports.js";
import type { ToolContext } from "../types.js";
import { createGitTools } from "./git.js";

const ctx = (): ToolContext => ({
  sessionId: "s1",
  runId: "r1",
  userId: "u1",
  mode: "auto",
  planMode: false,
  isSubagent: false,
  depth: 0,
  unattended: false,
  callKey: "toolcall-1",
  signal: new AbortController().signal,
});

function fakeSandbox(
  execImpl?: (cmd: string) => { exitCode: number; stdout: string; stderr: string },
) {
  const execs: string[] = [];
  const sandbox: SandboxPort = {
    async exec(_userId, o) {
      execs.push(o.cmd);
      return execImpl?.(o.cmd) ?? { exitCode: 0, stdout: "", stderr: "" };
    },
    async killCall() {},
    async readFile() {
      return "";
    },
    async writeFile() {},
    async exists() {
      return false;
    },
    async listDir() {
      return [];
    },
    async jobStart() {
      return { jobId: "j1" };
    },
    async jobOutput() {
      return { output: "", running: false, exitCode: 0 };
    },
    async jobList() {
      return [];
    },
    async jobKill() {},
  };
  return { sandbox, execs };
}

function approvals(decision: ApprovalDecision = "allow") {
  const seen: ApprovalRequest[] = [];
  const gate: ApprovalGate = {
    async approve(_ctx, request) {
      seen.push(request);
      return decision;
    },
  };
  return { gate, seen };
}

function tools(o: {
  exec?: (cmd: string) => { exitCode: number; stdout: string; stderr: string };
  decision?: ApprovalDecision;
}) {
  const sbx = fakeSandbox(o.exec);
  const appr = approvals(o.decision ?? "allow");
  const list = createGitTools({
    sandbox: sbx.sandbox,
    approvals: appr.gate,
    github: null,
  });
  const tool = list.find((t) => t.spec.name === "git_switch");
  if (tool === undefined) throw new Error("missing tool git_switch");
  return { tool, execs: sbx.execs, approvals: appr.seen };
}

describe("git_switch", () => {
  it("is registered", () => {
    const { tool } = tools({});
    expect(tool.spec.name).toBe("git_switch");
  });

  it("checks out an existing branch in the given repo directory", async () => {
    const { tool, execs } = tools({
      exec: (cmd) =>
        cmd.includes("status --porcelain")
          ? { exitCode: 0, stdout: "", stderr: "" }
          : cmd.includes("checkout")
            ? { exitCode: 0, stdout: "Switched to branch 'release'\n", stderr: "" }
            : { exitCode: 0, stdout: "", stderr: "" },
    });

    const result = await tool.execute(
      { path: "ovid-si", branch: "release" },
      ctx(),
    );

    expect(result.isError).not.toBe(true);
    expect(execs.some((c) => c.includes("checkout") && c.includes("release"))).toBe(true);
    expect(execs.some((c) => c.includes("ovid-si"))).toBe(true);
    expect(result.content).toContain("release");
  });

  it("creates the branch when asked", async () => {
    const { tool, execs } = tools({});
    await tool.execute({ branch: "feat/x", create: true }, ctx());
    expect(execs.some((c) => c.includes("-b") && c.includes("feat/x"))).toBe(true);
  });

  it("refuses a dirty working tree instead of silently carrying changes over", async () => {
    const { tool, execs } = tools({
      exec: (cmd) =>
        cmd.includes("status --porcelain")
          ? { exitCode: 0, stdout: " M src/a.ts\n", stderr: "" }
          : { exitCode: 0, stdout: "", stderr: "" },
    });

    const result = await tool.execute({ branch: "release" }, ctx());

    expect(result.isError).toBe(true);
    expect(result.content).toMatch(/uncommitted/i);
    // The checkout never ran.
    expect(execs.some((c) => c.includes("checkout"))).toBe(false);
  });

  it("switches anyway when the caller explicitly forces it", async () => {
    const { tool, execs } = tools({
      exec: (cmd) =>
        cmd.includes("status --porcelain")
          ? { exitCode: 0, stdout: " M src/a.ts\n", stderr: "" }
          : { exitCode: 0, stdout: "", stderr: "" },
    });

    const result = await tool.execute({ branch: "release", force: true }, ctx());

    expect(result.isError).not.toBe(true);
    expect(execs.some((c) => c.includes("checkout"))).toBe(true);
  });

  it("refuses a suspicious branch name before running anything", async () => {
    for (const bad of ["a b", "x..y", "main;rm -rf /", "--upload-pack=evil"]) {
      const { tool, execs } = tools({});
      const result = await tool.execute({ branch: bad }, ctx());
      expect(result.isError).toBe(true);
      expect(execs).toEqual([]);
    }
  });

  it("needs a branch", async () => {
    const { tool, execs } = tools({});
    const result = await tool.execute({}, ctx());
    expect(result.isError).toBe(true);
    expect(execs).toEqual([]);
  });

  it("asks the user first and does nothing on deny", async () => {
    const { tool, execs, approvals: seen } = tools({ decision: "deny" });
    const result = await tool.execute({ branch: "release" }, ctx());
    expect(result.content).toBe("DENIED by user");
    expect(seen).toHaveLength(1);
    expect(seen[0]!.allowAlways).toBe(false);
    expect(execs.some((c) => c.includes("checkout"))).toBe(false);
  });

  it("reports a git failure honestly", async () => {
    const { tool } = tools({
      exec: (cmd) =>
        cmd.includes("checkout")
          ? { exitCode: 1, stdout: "", stderr: "error: pathspec 'nope' did not match" }
          : { exitCode: 0, stdout: "", stderr: "" },
    });
    const result = await tool.execute({ branch: "nope" }, ctx());
    expect(result.isError).toBe(true);
    expect(result.content).toContain("did not match");
  });
});
