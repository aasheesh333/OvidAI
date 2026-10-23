// Task 11 — git/repo tools. Ports the git_*/commit/repo_tree/repo_sync
// dispatch cases from lib/core/agent_service.dart:
//   - git_status/log/diff/pull/clone/push + commit run git INSIDE the session
//     workspace jail via SandboxPort.exec (callKey threaded, output spilled);
//   - Dart approval parity: push is ALWAYS individually confirmed
//     (allowAlways:false), commit shows the staged-file list on the card,
//     clone prompts with the remote's host;
//   - repo_tree renders the Dart line-17827 'TREE (N files, showing 120)'
//     header via GitHubApiPort; repo_sync is the pinned cloud refusal
//     (P3-Q4: the device repo cache does not exist server-side).
// Safety legs ported from test/agent_git_tools_test.dart and the
// *commit_approval_test.dart / repo_cache_commit_safety_test.dart families
// (deny → 'DENIED by user' with NO mutation; the on-device repo cache itself
// is NOT ported — cloud git runs in the workspace jail).

import { describe, expect, it } from "vitest";

import type {
  ApprovalDecision,
  ApprovalGate,
  ApprovalRequest,
  GitHubApiPort,
  SandboxPort,
} from "../ports.js";
import type { ToolContext } from "../types.js";
import { createGitTools, createRepoTools } from "./git.js";

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

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

interface ExecRecord {
  userId: string;
  cmd: string;
  cwd?: string;
  callKey?: string;
  timeoutMs?: number;
}

function fakeSandbox(
  execImpl?: (cmd: string) => { exitCode: number; stdout: string; stderr: string },
) {
  const execs: ExecRecord[] = [];
  const writes: Array<{ userId: string; path: string; content: string }> = [];
  const sandbox: SandboxPort = {
    exec: async (userId, o) => {
      execs.push({ userId, cmd: o.cmd, cwd: o.cwd, callKey: o.callKey, timeoutMs: o.timeoutMs });
      if (execImpl) return execImpl(o.cmd);
      return { exitCode: 0, stdout: "", stderr: "" };
    },
    killCall: async () => {},
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
  return { sandbox, execs, writes };
}

function fakeGate(decision: ApprovalDecision) {
  const calls: ApprovalRequest[] = [];
  const gate: ApprovalGate = {
    async approve(_ctx, req) {
      calls.push(req);
      return decision;
    },
  };
  return { gate, calls };
}

type TreeEntry = { path: string; type: "blob" | "tree" };

function fakeGithub(entries: TreeEntry[]) {
  const calls: Array<{ userId: string; o: { owner: string; repo: string; ref?: string; recursive?: boolean } }> = [];
  const github: GitHubApiPort = {
    async getTree(userId, o) {
      calls.push({ userId, o });
      return entries;
    },
  };
  return { github, calls };
}

const gitTools = (sandbox: SandboxPort, gate: ApprovalGate) =>
  createGitTools({ sandbox, approvals: gate, github: null });

const byName = (tools: ReturnType<typeof createGitTools>, name: string) => {
  const t = tools.find((x) => x.spec.name === name);
  if (!t) throw new Error(`tool not found: ${name}`);
  return t;
};

// ---------------------------------------------------------------------------
// createGitTools — roster + read-only tools
// ---------------------------------------------------------------------------

describe("createGitTools", () => {
  it("advertises exactly the eight git tools", () => {
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const names = gitTools(sandbox, gate).map((t) => t.spec.name).sort();
    expect(names).toEqual([
      "commit",
      "git_clone",
      "git_diff",
      "git_log",
      "git_pull",
      "git_push",
      "git_status",
      "git_switch",
    ]);
  });

  it("git_status runs the porcelain status command in the workspace with the callKey threaded", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_status").execute({}, ctx());
    expect(execs).toHaveLength(1);
    expect(execs[0]).toMatchObject({
      userId: "u1",
      cmd: "git status --porcelain=v1 -b",
      cwd: ".",
      callKey: "toolcall-1",
    });
    expect(res.isError).toBeFalsy();
  });

  it("git_status empty output → 'no output' (Dart parity)", async () => {
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_status").execute({}, ctx());
    expect(res.content).toBe("no output");
  });

  it("git_log defaults to 20, clamps to 1–50, and accepts Dart's `n` alias", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const gitLog = byName(gitTools(sandbox, gate), "git_log");
    await gitLog.execute({}, ctx());
    await gitLog.execute({ limit: 5 }, ctx());
    await gitLog.execute({ limit: 100 }, ctx());
    await gitLog.execute({ n: 7 }, ctx());
    expect(execs.map((e) => e.cmd)).toEqual([
      "git log --oneline -20",
      "git log --oneline -5",
      "git log --oneline -50",
      "git log --oneline -7",
    ]);
  });

  it("git_log empty output → 'no commits' (Dart parity)", async () => {
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_log").execute({}, ctx());
    expect(res.content).toBe("no commits");
  });

  it("git_diff supports staged, stat and paths flags", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const gitDiff = byName(gitTools(sandbox, gate), "git_diff");
    await gitDiff.execute({ staged: true }, ctx());
    await gitDiff.execute({ paths: ["a.ts", "b.ts"] }, ctx());
    await gitDiff.execute({ staged: true, stat: true, paths: ["a.ts"] }, ctx());
    expect(execs.map((e) => e.cmd)).toEqual([
      "git diff --cached",
      "git diff -- 'a.ts' 'b.ts'",
      "git diff --cached --stat -- 'a.ts'",
    ]);
  });

  it("git_diff empty output → 'no changes' (Dart parity)", async () => {
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_diff").execute({}, ctx());
    expect(res.content).toBe("no changes");
  });

  it("a non-zero exit prefixes 'exit <code>' and keeps stdout+stderr verbatim", async () => {
    const { sandbox } = fakeSandbox(() => ({
      exitCode: 1,
      stdout: "## main...origin/main",
      stderr: "fatal: not a git repository",
    }));
    const { gate } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_status").execute({}, ctx());
    expect(res.content.startsWith("exit 1")).toBe(true);
    expect(res.content).toContain("fatal: not a git repository");
    expect(res.content).toContain("## main...origin/main");
    expect(res.isError).toBe(true);
  });

  it("oversized output spills to .spill with the omission notice", async () => {
    const { sandbox, writes } = fakeSandbox(() => ({
      exitCode: 0,
      stdout: "x".repeat(7000),
      stderr: "",
    }));
    const { gate } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_log").execute({}, ctx());
    expect(res.content).toContain("characters omitted");
    expect(writes.some((w) => w.path.startsWith(".spill/"))).toBe(true);
  });

  it("per-tool timeout budgets match the Dart _toolTimeoutFor map", () => {
    const { sandbox } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const tools = gitTools(sandbox, gate);
    const timeoutOf = (name: string) => byName(tools, name).timeoutMs;
    expect(timeoutOf("commit")).toBe(180_000);
    expect(timeoutOf("git_push")).toBe(300_000);
    expect(timeoutOf("git_pull")).toBe(300_000);
    expect(timeoutOf("git_clone")).toBe(300_000);
    expect(timeoutOf("git_status")).toBe(120_000);
  });
});

// ---------------------------------------------------------------------------
// git_pull / git_push / git_clone — approval parity
// ---------------------------------------------------------------------------

describe("git remote tools approval parity", () => {
  it("git_pull prompts, then pulls --ff-only; empty output → 'already up to date ✓'", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_pull").execute({}, ctx());
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ kind: "tool", tool: "git_pull" });
    expect(calls[0].summary).toBe("Pull from origin (fast-forward only)");
    expect(execs.map((e) => e.cmd)).toEqual(["git pull --ff-only 'origin'"]);
    expect(res.content).toBe("already up to date ✓");
  });

  it("git_pull with branch appends it and the branch lands on the card", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    await byName(gitTools(sandbox, gate), "git_pull").execute({ branch: "dev" }, ctx());
    expect(execs[0].cmd).toBe("git pull --ff-only 'origin' 'dev'");
    expect(calls[0].summary).toBe("Pull dev from origin (fast-forward only)");
  });

  it("git_pull deny → 'DENIED by user' and NOTHING execs", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate } = fakeGate("deny");
    const res = await byName(gitTools(sandbox, gate), "git_pull").execute({}, ctx());
    expect(res.content).toBe("DENIED by user");
    expect(execs).toHaveLength(0);
  });

  it("git_push ALWAYS prompts with allowAlways:false even when a grant answers 'always'", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate, calls } = fakeGate("always");
    const res = await byName(gitTools(sandbox, gate), "git_push").execute({}, ctx());
    // The gate answered an existing-session-grant style "always", but the
    // REQUEST must still have been raised with allowAlways:false — pushes
    // are individually confirmed (Dart parity).
    expect(calls).toHaveLength(1);
    expect(calls[0].allowAlways).toBe(false);
    expect(calls[0].tool).toBe("git_push");
    expect(execs.map((e) => e.cmd)).toEqual(["git push 'origin'"]);
    expect(res.content).toBe("pushed ✓");
  });

  it("git_push with branch uses --set-upstream (Dart argv parity)", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate } = fakeGate("allow");
    await byName(gitTools(sandbox, gate), "git_push").execute({ branch: "dev" }, ctx());
    expect(execs[0].cmd).toBe("git push --set-upstream 'origin' 'dev'");
  });

  it("git_push deny → 'DENIED by user' and NOTHING execs", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate } = fakeGate("deny");
    const res = await byName(gitTools(sandbox, gate), "git_push").execute({}, ctx());
    expect(res.content).toBe("DENIED by user");
    expect(execs).toHaveLength(0);
  });

  it("git_push with an empty remote name is refused before any prompt", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_push").execute({ remote: " " }, ctx());
    expect(res.content).toBe("git_push needs a remote name.");
    expect(calls).toHaveLength(0);
    expect(execs).toHaveLength(0);
  });

  it("git_clone prompts with the remote's hostTargets; deny → 'DENIED by user', no exec", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate, calls } = fakeGate("deny");
    const res = await byName(gitTools(sandbox, gate), "git_clone").execute(
      { url: "https://github.com/foo/bar.git" },
      ctx(),
    );
    expect(calls).toHaveLength(1);
    expect(calls[0].hostTargets).toEqual(["github.com"]);
    expect(calls[0].kind).toBe("tool");
    expect(res.content).toBe("DENIED by user");
    expect(execs).toHaveLength(0);
  });

  it("git_clone allow execs an argv-quoted clone with optional branch and dest", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_clone").execute(
      { url: "https://github.com/foo/bar.git", branch: "dev", path: "mydir" },
      ctx(),
    );
    expect(execs[0].cmd).toBe(
      "git clone -b 'dev' 'https://github.com/foo/bar.git' 'mydir'",
    );
    expect(res.content).toBe("cloned https://github.com/foo/bar.git ✓");
  });

  it("git_clone extracts the host from scp-like URLs", async () => {
    const { sandbox } = fakeSandbox();
    const { gate, calls } = fakeGate("deny");
    await byName(gitTools(sandbox, gate), "git_clone").execute(
      { url: "git@gitlab.com:foo/bar.git" },
      ctx(),
    );
    expect(calls[0].hostTargets).toEqual(["gitlab.com"]);
  });

  it("git_clone refuses suspicious branch names without prompting (Dart parity)", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "git_clone").execute(
      { url: "https://github.com/foo/bar.git", branch: "../evil" },
      ctx(),
    );
    expect(res.content).toBe('git_clone: refusing suspicious branch name "../evil".');
    expect(calls).toHaveLength(0);
    expect(execs).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// commit — staged-list approval card (agent_commit_approval / chat+studio
// commit-approval + repo_cache commit-safety legs)
// ---------------------------------------------------------------------------

describe("commit approval parity", () => {
  const commitSandbox = () =>
    fakeSandbox((cmd) => {
      if (cmd === "git diff --cached --name-only") {
        return { exitCode: 0, stdout: "a.ts\nb.ts\n", stderr: "" };
      }
      if (cmd.startsWith("git commit -m")) {
        return { exitCode: 0, stdout: "[main 1a2b3c4] Fix things", stderr: "" };
      }
      return { exitCode: 0, stdout: "", stderr: "" };
    });

  it("allow: the card shows the staged-file list first, then execs git commit -m", async () => {
    const { sandbox, execs } = commitSandbox();
    const { gate, calls } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "commit").execute(
      { message: "Fix things" },
      ctx(),
    );
    // The approval summary shows the staged-file list (via
    // `git diff --cached --name-only`) BEFORE any mutation is possible.
    expect(calls).toHaveLength(1);
    expect(calls[0].kind).toBe("tool");
    expect(calls[0].tool).toBe("commit");
    expect(calls[0].summary).toContain("a.ts");
    expect(calls[0].summary).toContain("b.ts");
    expect(calls[0].detail).toContain("Fix things");
    expect(execs.some((e) => e.cmd === "git commit -m 'Fix things'")).toBe(true);
    const commitExec = execs.find((e) => e.cmd.startsWith("git commit"));
    expect(commitExec).toMatchObject({ cwd: ".", callKey: "toolcall-1" });
    expect(res.content).toBe("[main 1a2b3c4] Fix things");
  });

  it("deny → 'DENIED by user' and NO commit exec", async () => {
    const { sandbox, execs } = commitSandbox();
    const { gate, calls } = fakeGate("deny");
    const res = await byName(gitTools(sandbox, gate), "commit").execute(
      { message: "Fix things" },
      ctx(),
    );
    expect(res.content).toBe("DENIED by user");
    expect(calls).toHaveLength(1);
    // The only exec is the read-only staged-list pre-flight — a denial
    // must never reach `git commit`.
    expect(execs.every((e) => !e.cmd.startsWith("git commit"))).toBe(true);
  });

  it("nothing staged → 'no pending changes', no card raised", async () => {
    const { sandbox, execs } = fakeSandbox();
    const { gate, calls } = fakeGate("allow");
    const res = await byName(gitTools(sandbox, gate), "commit").execute(
      { message: "Fix things" },
      ctx(),
    );
    expect(res.content).toBe("no pending changes");
    expect(calls).toHaveLength(0);
    expect(execs.every((e) => !e.cmd.startsWith("git commit"))).toBe(true);
  });

  it("single-quotes the message safely (apostrophes cannot break out)", async () => {
    const { sandbox, execs } = commitSandbox();
    const { gate } = fakeGate("allow");
    await byName(gitTools(sandbox, gate), "commit").execute(
      { message: "it's done" },
      ctx(),
    );
    expect(execs.some((e) => e.cmd === "git commit -m 'it'\\''s done'")).toBe(true);
  });

  it("commit is individually confirmed — the card never offers always-allow", async () => {
    const { sandbox } = commitSandbox();
    const { gate, calls } = fakeGate("allow");
    await byName(gitTools(sandbox, gate), "commit").execute({ message: "m" }, ctx());
    expect(calls[0].allowAlways).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// createRepoTools
// ---------------------------------------------------------------------------

describe("createRepoTools", () => {
  it("with github: repo_sync + repo_tree; with github:null: repo_tree is ABSENT (the roster never advertises what cannot run)", () => {
    const withGithub = createRepoTools({ github: fakeGithub([]).github });
    expect(withGithub.map((t) => t.spec.name).sort()).toEqual(["repo_sync", "repo_tree"]);

    const withoutGithub = createRepoTools({ github: null });
    expect(withoutGithub.map((t) => t.spec.name)).toEqual(["repo_sync"]);
  });

  it("repo_sync returns the pinned cloud-deviation refusal", async () => {
    const tools = createRepoTools({ github: null });
    const res = await tools[0].execute({}, ctx());
    expect(res.content).toBe(
      "repo_sync is not available in cloud workspaces — use git_pull/git_push in the workspace",
    );
  });

  it("repo_tree renders the 120-path cap header exactly (Dart line 17827 parity)", async () => {
    const entries: TreeEntry[] = Array.from({ length: 150 }, (_, i) => ({
      path: `f${i}.ts`,
      type: "blob" as const,
    }));
    const { github } = fakeGithub(entries);
    const repoTree = createRepoTools({ github }).find((t) => t.spec.name === "repo_tree")!;
    const res = await repoTree.execute({ owner: "foo", repo: "bar" }, ctx());
    const expected =
      "TREE (150 files, showing 120):\n" +
      Array.from({ length: 120 }, (_, i) => `f${i}.ts`).join("\n");
    expect(res.content).toBe(expected);
  });

  it("repo_tree passes owner/repo/ref with recursive and filters by path prefix (blobs only)", async () => {
    const entries: TreeEntry[] = [
      { path: "src", type: "tree" },
      { path: "src/a.ts", type: "blob" },
      { path: "src/b.ts", type: "blob" },
      { path: "README.md", type: "blob" },
    ];
    const { github, calls } = fakeGithub(entries);
    const repoTree = createRepoTools({ github }).find((t) => t.spec.name === "repo_tree")!;
    const res = await repoTree.execute(
      { owner: "foo", repo: "bar", ref: "dev", path: "src" },
      ctx(),
    );
    expect(calls[0]).toEqual({
      userId: "u1",
      o: { owner: "foo", repo: "bar", ref: "dev", recursive: true },
    });
    expect(res.content).toBe("TREE (2 files, showing 120):\nsrc/a.ts\nsrc/b.ts");
  });

  it("repo_tree with an empty result → a plain no-files answer (not the device repo_sync copy)", async () => {
    const { github } = fakeGithub([]);
    const repoTree = createRepoTools({ github }).find((t) => t.spec.name === "repo_tree")!;
    const res = await repoTree.execute({ owner: "foo", repo: "bar" }, ctx());
    expect(res.content).toBe("no files found in this repository/ref");
  });

  it("repo_tree failure → 'repo_tree failed: …' (never a throw)", async () => {
    const github: GitHubApiPort = {
      async getTree() {
        throw new Error("HTTP 404");
      },
    };
    const repoTree = createRepoTools({ github }).find((t) => t.spec.name === "repo_tree")!;
    const res = await repoTree.execute({ owner: "foo", repo: "bar" }, ctx());
    expect(res.content).toBe("repo_tree failed: HTTP 404");
  });
});
