import { afterEach, describe, expect, it, vi } from "vitest";

import type { SandboxPort } from "../ports.js";
import type { Tool, ToolContext, ToolResult } from "../types.js";
import { TOOL_TIMEOUT_MESSAGE, withToolTimeout } from "./spill.js";
import { createSandboxTools } from "./sandboxTools.js";

interface ExecCall {
  userId: string;
  o: { cmd: string; cwd?: string; timeoutMs?: number; callKey?: string; env?: Record<string, string> };
}

function fakeSandbox() {
  const files = new Map<string, string>();
  const rec = {
    execCalls: [] as ExecCall[],
    kills: [] as Array<[string, string]>,
    jobStarts: [] as Array<{ userId: string; o: { cmd: string; cwd?: string } }>,
    jobOutputCalls: [] as Array<{ userId: string; jobId: string; o?: { offset?: number } }>,
    jobKills: [] as string[],
    jobLists: 0,
    writes: [] as Array<{ userId: string; path: string; content: string }>,
    reads: [] as string[],
  };
  let execResult: { exitCode: number; stdout: string; stderr: string } = {
    exitCode: 0,
    stdout: "",
    stderr: "",
  };
  const startedJobs = new Set<string>();
  let neverResolve = false;
  const sandbox: SandboxPort = {
    exec: async (userId, o) => {
      rec.execCalls.push({ userId, o });
      if (neverResolve) return new Promise(() => {});
      return execResult;
    },
    killCall: async (userId, callKey) => {
      rec.kills.push([userId, callKey]);
    },
    readFile: async (userId, path) => {
      rec.reads.push(path);
      const c = files.get(path);
      if (c === undefined) throw new Error(`no such file: ${path}`);
      return c;
    },
    writeFile: async (userId, path, content) => {
      rec.writes.push({ userId, path, content });
      files.set(path, content);
    },
    exists: async (_userId, path) => files.has(path),
    listDir: async () => [...files.keys()],
    jobStart: async (userId, o) => {
      rec.jobStarts.push({ userId, o });
      const jobId = `job-${rec.jobStarts.length}`;
      startedJobs.add(jobId);
      return { jobId };
    },
    jobOutput: async (userId, jobId, o) => {
      if (!startedJobs.has(jobId)) throw new Error(`no such job: ${jobId}`);
      rec.jobOutputCalls.push({ userId, jobId, o });
      return { output: "hello world", running: true, exitCode: null };
    },
    jobList: async () => {
      rec.jobLists += 1;
      return [
        { jobId: "job-1", cmd: "npm run dev", running: true },
        { jobId: "job-2", cmd: "watcher", running: false },
      ];
    },
    jobKill: async (_userId, jobId) => {
      rec.jobKills.push(jobId);
    },
  };
  return {
    sandbox,
    rec,
    files,
    setExecResult: (r: { exitCode: number; stdout: string; stderr: string }) => {
      execResult = r;
    },
    setNeverResolve: () => {
      neverResolve = true;
    },
  };
}

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

const byName = (tools: Tool[], name: string): Tool => {
  const t = tools.find((x) => x.spec.name === name);
  if (!t) throw new Error(`no such tool: ${name}`);
  return t;
};

afterEach(() => {
  vi.useRealTimers();
});

describe("createSandboxTools roster", () => {
  it("returns the P3 additive tool set with per-tool timeouts and specs", () => {
    const { sandbox } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    expect(tools.map((t) => t.spec.name).sort()).toEqual(
      [
        "run_code",
        "file_read",
        "file_write",
        "fs_edit",
        "multi_edit",
        "notebook_edit",
        "fs_glob",
        "fs_grep",
        "job_start",
        "job_output",
        "job_list",
        "job_kill",
      ].sort(),
    );
    for (const t of tools) {
      expect(t.spec.description.length).toBeGreaterThan(0);
      expect(t.spec.parameters).toHaveProperty("type");
      expect(t.timeoutMs).toBeGreaterThan(0);
    }
    const timeout = new Map(tools.map((t) => [t.spec.name, t.timeoutMs] as const));
    expect(timeout.get("run_code")).toBe(300_000);
    expect(timeout.get("job_start")).toBe(300_000);
    expect(timeout.get("fs_grep")).toBe(45_000);
    expect(timeout.get("fs_glob")).toBe(45_000);
    expect(timeout.get("file_read")).toBe(120_000);
  });
});

describe("run_code", () => {
  it("refuses any language but python/javascript with the exact string and no exec", async () => {
    const { sandbox, rec } = fakeSandbox();
    const runCode = byName(createSandboxTools({ sandbox }), "run_code");
    const res = await runCode.execute({ code: "puts 1", lang: "ruby" }, ctx());
    expect(res).toEqual({
      content: "Unsupported language: ruby. Use python or javascript.",
      isError: true,
    });
    expect(rec.execCalls).toEqual([]);
  });

  it("defaults to python and threads callKey through to sandbox.exec", async () => {
    const { sandbox, rec, setExecResult } = fakeSandbox();
    setExecResult({ exitCode: 0, stdout: "42\n", stderr: "" });
    const res = await byName(createSandboxTools({ sandbox }), "run_code").execute(
      { code: "print(6 * 7)" },
      ctx(),
    );
    expect(rec.execCalls).toHaveLength(1);
    expect(rec.execCalls[0].userId).toBe("u1");
    expect(rec.execCalls[0].o.cmd).toContain("python3 -c");
    expect(rec.execCalls[0].o.callKey).toBe("toolcall-1");
    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("42");
    expect(res.content).toContain("[exit 0]");
  });

  it("runs javascript via node -e", async () => {
    const { sandbox, rec } = fakeSandbox();
    await byName(createSandboxTools({ sandbox }), "run_code").execute(
      { code: "console.log(1)", lang: "javascript" },
      ctx(),
    );
    expect(rec.execCalls[0].o.cmd).toContain("node -e");
  });

  it("marks a non-zero exit as an error", async () => {
    const { sandbox, setExecResult } = fakeSandbox();
    setExecResult({ exitCode: 1, stdout: "", stderr: "Traceback" });
    const res = await byName(createSandboxTools({ sandbox }), "run_code").execute(
      { code: "1/0" },
      ctx(),
    );
    expect(res.isError).toBe(true);
    expect(res.content).toContain("Traceback");
  });

  it("requires a code string", async () => {
    const { sandbox, rec } = fakeSandbox();
    const res = await byName(createSandboxTools({ sandbox }), "run_code").execute({}, ctx());
    expect(res.isError).toBe(true);
    expect(res.content).toContain("invalid_input");
    expect(rec.execCalls).toEqual([]);
  });
});

describe("fs_grep", () => {
  it("passes pattern, cwd and callKey through to sandbox.exec", async () => {
    const { sandbox, rec, setExecResult } = fakeSandbox();
    setExecResult({ exitCode: 0, stdout: "src/a.ts:1:foo\n", stderr: "" });
    const res = await byName(createSandboxTools({ sandbox }), "fs_grep").execute(
      { pattern: "foo", path: "src" },
      ctx(),
    );
    expect(rec.execCalls).toHaveLength(1);
    expect(rec.execCalls[0].o.cmd).toContain("foo");
    expect(rec.execCalls[0].o.cwd).toBe("src");
    expect(rec.execCalls[0].o.callKey).toBe("toolcall-1");
    expect(res.content).toContain("src/a.ts:1:foo");
  });

  it("spills a >6000-char stdout to .spill/ with the fs_grep locator", async () => {
    const { sandbox, rec, setExecResult } = fakeSandbox();
    setExecResult({ exitCode: 0, stdout: "m".repeat(7000), stderr: "" });
    const res = await byName(createSandboxTools({ sandbox }), "fs_grep").execute(
      { pattern: "foo" },
      ctx(),
    );
    const write = rec.writes.find((w) => w.path.startsWith(".spill/"));
    expect(write).toBeDefined();
    expect(write!.content).toBe("m".repeat(7000));
    expect(res.content).toContain("characters omitted");
    expect(res.content).toContain("narrower `pattern`");
  });

  it("exit 1 means no matches, not an error", async () => {
    const { sandbox, setExecResult } = fakeSandbox();
    setExecResult({ exitCode: 1, stdout: "", stderr: "" });
    const res = await byName(createSandboxTools({ sandbox }), "fs_grep").execute(
      { pattern: "zzz" },
      ctx(),
    );
    expect(res.content).toContain("no matches for zzz");
    expect(res.isError).toBeFalsy();
  });
});

describe("fs_glob", () => {
  it("matches **/*.dart across depths and threads callKey", async () => {
    const { sandbox, rec, setExecResult } = fakeSandbox();
    setExecResult({
      exitCode: 0,
      stdout: "./a.dart\n./src/b.ts\n./src/c.dart\n./deep/dir/d.dart\n",
      stderr: "",
    });
    const res = await byName(createSandboxTools({ sandbox }), "fs_glob").execute(
      { pattern: "**/*.dart" },
      ctx(),
    );
    expect(rec.execCalls[0].o.callKey).toBe("toolcall-1");
    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("a.dart");
    expect(res.content).toContain("src/c.dart");
    expect(res.content).toContain("deep/dir/d.dart");
    expect(res.content).not.toContain("b.ts");
  });

  it("single-segment * does not cross directory boundaries", async () => {
    const { sandbox, setExecResult } = fakeSandbox();
    setExecResult({ exitCode: 0, stdout: "./top.js\n./nested/inner.js\n", stderr: "" });
    const res = await byName(createSandboxTools({ sandbox }), "fs_glob").execute(
      { pattern: "*.js" },
      ctx(),
    );
    expect(res.content).toContain("top.js");
    expect(res.content).not.toContain("nested/inner.js");
  });

  it("reports when nothing matches", async () => {
    const { sandbox, setExecResult } = fakeSandbox();
    setExecResult({ exitCode: 0, stdout: "", stderr: "" });
    const res = await byName(createSandboxTools({ sandbox }), "fs_glob").execute(
      { pattern: "**/*.zz" },
      ctx(),
    );
    expect(res.content).toContain("no matches for pattern **/*.zz");
  });
});

describe("file_read / file_write", () => {
  it("file_write then file_read round-trips through the sandbox with numbered lines", async () => {
    const { sandbox, rec } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    const w = await byName(tools, "file_write").execute(
      { path: "notes/a.txt", content: "alpha\nbeta\n" },
      ctx(),
    );
    expect(w.isError).toBeFalsy();
    expect(rec.writes[0].path).toBe("notes/a.txt");

    const r = await byName(tools, "file_read").execute({ path: "notes/a.txt" }, ctx());
    expect(r.content).toContain("     1\talpha");
    expect(r.content).toContain("     2\tbeta");
    expect(r.isError).toBeFalsy();
  });

  it("file_read windows by 1-based offset/limit and reports the total", async () => {
    const { sandbox } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    await byName(tools, "file_write").execute(
      { path: "w.txt", content: "l1\nl2\nl3\n" },
      ctx(),
    );
    const res = await byName(tools, "file_read").execute(
      { path: "w.txt", offset: 2, limit: 1 },
      ctx(),
    );
    expect(res.content).toContain("l2");
    expect(res.content).not.toContain("l1\n");
    expect(res.content).toContain("of 3");
  });

  it("file_read of a missing file is an error, not a throw", async () => {
    const { sandbox } = fakeSandbox();
    const res = await byName(createSandboxTools({ sandbox }), "file_read").execute(
      { path: "nope.txt" },
      ctx(),
    );
    expect(res.isError).toBe(true);
    expect(res.content).toContain("no such file");
  });
});

describe("fs_edit", () => {
  it("view numbers lines; create writes a new file and refuses an existing one", async () => {
    const { sandbox } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    const c = await byName(tools, "fs_edit").execute(
      { command: "create", path: "new.txt", file_text: "hello\n" },
      ctx(),
    );
    expect(c.isError).toBeFalsy();
    const again = await byName(tools, "fs_edit").execute(
      { command: "create", path: "new.txt", file_text: "x" },
      ctx(),
    );
    expect(again.isError).toBe(true);
    expect(again.content).toContain("file already exists: new.txt");

    const v = await byName(tools, "fs_edit").execute(
      { command: "view", path: "new.txt" },
      ctx(),
    );
    expect(v.content).toContain("hello");
  });

  it("str_replace replaces the unique match and refuses zero/multiple matches", async () => {
    const { sandbox, files } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    await byName(tools, "fs_edit").execute(
      { command: "create", path: "e.txt", file_text: "hello world\n" },
      ctx(),
    );
    const ok = await byName(tools, "fs_edit").execute(
      { command: "str_replace", path: "e.txt", old_str: "world", new_str: "there" },
      ctx(),
    );
    expect(ok.isError).toBeFalsy();
    expect(files.get("e.txt")).toBe("hello there\n");

    const missing = await byName(tools, "fs_edit").execute(
      { command: "str_replace", path: "e.txt", old_str: "zzz", new_str: "y" },
      ctx(),
    );
    expect(missing.isError).toBe(true);
    expect(missing.content).toContain("old_str not found");

    await byName(tools, "file_write").execute({ path: "twice.txt", content: "x y x\n" }, ctx());
    const dup = await byName(tools, "fs_edit").execute(
      { command: "str_replace", path: "twice.txt", old_str: "x", new_str: "z" },
      ctx(),
    );
    expect(dup.isError).toBe(true);
    expect(dup.content).toContain("matches 2 times");
  });

  it("insert drops new_str after the given line", async () => {
    const { sandbox, files } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    await byName(tools, "file_write").execute(
      { path: "i.txt", content: "a\nb\n" },
      ctx(),
    );
    const res = await byName(tools, "fs_edit").execute(
      { command: "insert", path: "i.txt", new_str: "INSERTED\n", insert_line: 1 },
      ctx(),
    );
    expect(res.isError).toBeFalsy();
    expect(files.get("i.txt")).toBe("a\nINSERTED\nb\n");
  });
});

describe("multi_edit", () => {
  it("applies edits sequentially and atomically through the sandbox", async () => {
    const { sandbox, files } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    await byName(tools, "file_write").execute({ path: "m.txt", content: "one two\n" }, ctx());
    const ok = await byName(tools, "multi_edit").execute(
      {
        file_path: "m.txt",
        edits: [
          { old_string: "one", new_string: "1" },
          { old_str: "1 two", new_str: "uno" },
        ],
      },
      ctx(),
    );
    expect(ok.isError).toBeFalsy();
    expect(files.get("m.txt")).toBe("uno\n");
  });

  it("a failing edit writes NOTHING and names the edit index", async () => {
    const { sandbox, files } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    await byName(tools, "file_write").execute({ path: "m.txt", content: "one two\n" }, ctx());
    const bad = await byName(tools, "multi_edit").execute(
      {
        file_path: "m.txt",
        edits: [
          { old_string: "one", new_string: "1" },
          { old_string: "missing", new_string: "?" },
        ],
      },
      ctx(),
    );
    expect(bad.isError).toBe(true);
    expect(bad.content).toMatch(/edit 2/);
    expect(files.get("m.txt")).toBe("one two\n");
  });

  it("creates a missing file when the first edit's old_string is empty", async () => {
    const { sandbox, files } = fakeSandbox();
    const res = await byName(createSandboxTools({ sandbox }), "multi_edit").execute(
      { file_path: "born.txt", edits: [{ old_string: "", new_string: "created\n" }] },
      ctx(),
    );
    expect(res.isError).toBeFalsy();
    expect(files.get("born.txt")).toBe("created\n");
  });
});

describe("notebook_edit", () => {
  const notebook = JSON.stringify({
    cells: [
      { cell_type: "markdown", id: "intro", metadata: {}, source: ["# T\n"] },
      {
        cell_type: "code",
        id: "calc",
        metadata: {},
        execution_count: 3,
        outputs: [],
        source: ["print(1 + 1)"],
      },
    ],
    metadata: {},
    nbformat: 4,
    nbformat_minor: 5,
  });

  it("replaces one cell's source and preserves the rest", async () => {
    const { sandbox, rec } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    await byName(tools, "file_write").execute({ path: "nb.ipynb", content: notebook }, ctx());
    const res = await byName(tools, "notebook_edit").execute(
      { notebook_path: "nb.ipynb", cell_id: "calc", new_source: "print(2)" },
      ctx(),
    );
    expect(res.isError).toBeFalsy();
    const written = rec.writes[rec.writes.length - 1].content;
    const parsed = JSON.parse(written) as { cells: Array<Record<string, unknown>> };
    const calc = parsed.cells.find((c) => c.id === "calc")!;
    expect(calc.source).toEqual(["print(2)"]);
    expect(calc.execution_count).toBe(3);
    expect(parsed.cells.find((c) => c.id === "intro")).toBeDefined();
  });
});

describe("job tools", () => {
  it("job_start → job_output offset round-trip → job_list → job_kill", async () => {
    const { sandbox, rec } = fakeSandbox();
    const tools = createSandboxTools({ sandbox });
    const start = await byName(tools, "job_start").execute(
      { command: "npm run dev", name: "dev-server" },
      ctx(),
    );
    expect(start.isError).toBeFalsy();
    expect(start.content).toContain("job-1");
    expect(rec.jobStarts[0].o.cmd).toBe("npm run dev");

    const out = await byName(tools, "job_output").execute(
      { job_id: "job-1", offset: 12 },
      ctx(),
    );
    expect(rec.jobOutputCalls[0].jobId).toBe("job-1");
    expect(rec.jobOutputCalls[0].o?.offset).toBe(12);
    expect(out.content).toContain("hello world");
    expect(out.content).toContain("job-1");

    const list = await byName(tools, "job_list").execute({}, ctx());
    expect(list.content).toContain("job-1");
    expect(list.content).toContain("npm run dev");

    const kill = await byName(tools, "job_kill").execute({ job_id: "job-1" }, ctx());
    expect(kill.isError).toBeFalsy();
    expect(rec.jobKills).toEqual(["job-1"]);
  });

  it("job_output of an unknown job is an error", async () => {
    const { sandbox } = fakeSandbox();
    const res = await byName(createSandboxTools({ sandbox }), "job_output").execute(
      { job_id: "job-x" },
      ctx(),
    );
    expect(res.isError).toBe(true);
    expect(res.content).toContain("no such job");
  });
});

describe("timeout/kill contract (ported from tool_timeout_cancel_test.dart)", () => {
  it("a never-resolving exec-class tool is killed by callKey and reported KILLED", async () => {
    vi.useFakeTimers();
    const { sandbox, rec, setNeverResolve } = fakeSandbox();
    setNeverResolve();
    const tools = createSandboxTools({ sandbox });
    const fakeRunShell: Tool = {
      spec: { name: "run_shell", description: "fake exec tool", parameters: { type: "object" } },
      timeoutMs: 600_000,
      execute: (_args, ctx) =>
        sandbox.exec(ctx.userId, { cmd: "sleep 1000", callKey: ctx.callKey }).then(
          () => ({ content: "never" }) as ToolResult,
        ),
    };
    const wrapped = withToolTimeout(fakeRunShell.execute({}, ctx()), {
      timeoutMs: 600_000,
      callKey: "toolcall-1",
      toolName: "run_shell",
      onKill: () => sandbox.killCall("u1", "toolcall-1"),
    });
    await vi.advanceTimersByTimeAsync(600_000);
    const res = await wrapped;
    expect(rec.kills).toEqual([["u1", "toolcall-1"]]);
    expect(res.content).toBe(TOOL_TIMEOUT_MESSAGE("run_shell", 600));
    expect(res.isError).toBe(true);
  });

  it("the same contract holds for a roster tool (run_code) via its own budget", async () => {
    vi.useFakeTimers();
    const { sandbox, rec, setNeverResolve } = fakeSandbox();
    setNeverResolve();
    const runCode = byName(createSandboxTools({ sandbox }), "run_code");
    const wrapped = withToolTimeout(runCode.execute({ code: "import time; time.sleep(999)" }, ctx()), {
      timeoutMs: runCode.timeoutMs,
      callKey: "toolcall-1",
      toolName: "run_code",
      onKill: () => sandbox.killCall("u1", "toolcall-1"),
    });
    await vi.advanceTimersByTimeAsync(runCode.timeoutMs);
    const res = await wrapped;
    expect(rec.kills).toEqual([["u1", "toolcall-1"]]);
    expect(res.content).toBe(TOOL_TIMEOUT_MESSAGE("run_code", 300));
    expect(res.isError).toBe(true);
  });
});
