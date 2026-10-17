// Hooks engine (P3 Task 18) — ported from the Dart hook suite:
// hook_stdin_test.dart, hook_security_test.dart, hook_matcher_parity_test.dart,
// hook_allow_bypass_test.dart, parallel_hooks_contract_test.dart,
// wave2_hooks_lifecycle_test.dart, claude_code_hooks_mcp_parity_test.dart,
// hook_blocker_diagnostics_test.dart, hook_w07_test.dart,
// superpowers_hook_e2e_test.dart (synthetic fixture).
//
// CUT-with-comment (see hooks.ts header): agent-type hooks, session_end /
// permission_request / pre_compact / post_compact / subagent_start events,
// env-file persistence, plugin runtime/registry lifecycle, encrypted context
// restore, async hooks, and the misnamed agent_hook_integration_test.dart
// (which actually pins image-gateway accounting, not hooks).

import { describe, expect, it } from "vitest";

import type { SandboxPort } from "./ports.js";
import { ccToolInput, nativeToolInput } from "./claudeCodeTools.js";
import {
  HOOK_BREAKER_THRESHOLD,
  createFileHookSource,
  createHookEngine,
  parsePromptHookDecision,
  redactHookPayload,
  type HookDefinition,
  type HookSource,
} from "./hooks.js";

// ---------------------------------------------------------------------------
// Fake SandboxPort: captures cmd/env and decodes the stdin wrapper.
// ---------------------------------------------------------------------------

interface ExecCall {
  userId: string;
  o: {
    cmd: string;
    cwd?: string;
    timeoutMs?: number;
    callKey?: string;
    env?: Record<string, string>;
  };
}

type ExecResult = { exitCode: number; stdout: string; stderr: string };

function decodeStdin(cmd: string): string {
  const prefix = "printf '%s' '";
  const start = cmd.indexOf(prefix);
  if (start < 0) throw new Error(`no stdin wrapper in: ${cmd.slice(0, 120)}`);
  const bodyStart = start + prefix.length;
  const end = cmd.indexOf("' | (", bodyStart);
  if (end < 0) throw new Error("unterminated stdin wrapper");
  return cmd.slice(bodyStart, end).replace(/'\\''/g, "'");
}

function fakeSandbox() {
  const files = new Map<string, string>();
  const execCalls: ExecCall[] = [];
  const kills: Array<[string, string]> = [];
  let handler: (call: ExecCall) => Promise<ExecResult> | ExecResult = () => ({
    exitCode: 0,
    stdout: "",
    stderr: "",
  });

  const sandbox: SandboxPort = {
    async exec(userId, o) {
      const call = { userId, o };
      execCalls.push(call);
      return handler(call);
    },
    async killCall(userId, callKey) {
      kills.push([userId, callKey]);
    },
    async readFile(_userId, path) {
      const content = files.get(path);
      if (content === undefined) throw new Error(`no such file: ${path}`);
      return content;
    },
    async writeFile(_userId, path, content) {
      files.set(path, content);
    },
    async exists(_userId, path) {
      return files.has(path);
    },
    async listDir() {
      return [...files.keys()];
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

  return {
    sandbox,
    files,
    execCalls,
    kills,
    setHandler(fn: (call: ExecCall) => Promise<ExecResult> | ExecResult) {
      handler = fn;
    },
  };
}

function staticSource(hooks: HookDefinition[]): HookSource {
  return {
    async hooksFor() {
      return hooks;
    },
  };
}

function def(overrides: Partial<HookDefinition> & { event: HookDefinition["event"] }): HookDefinition {
  return {
    id: overrides.id ?? "h1",
    pluginId: overrides.pluginId ?? "plugin-a",
    event: overrides.event,
    type: overrides.type ?? "command",
    ...(overrides.matcher !== undefined ? { matcher: overrides.matcher } : {}),
    ...(overrides.command !== undefined ? { command: overrides.command } : {}),
    ...(overrides.prompt !== undefined ? { prompt: overrides.prompt } : {}),
    ...(overrides.timeoutMs !== undefined ? { timeoutMs: overrides.timeoutMs } : {}),
    ...(overrides.if !== undefined ? { if: overrides.if } : {}),
  };
}

const ok = (stdout = "", stderr = ""): ExecResult => ({ exitCode: 0, stdout, stderr });

function makeEngine(
  fs: ReturnType<typeof fakeSandbox>,
  hooks: HookDefinition[],
  extra: Partial<Parameters<typeof createHookEngine>[0]> = {},
) {
  const notifications: Array<{ message: string; sessionId: string; pluginId: string }> = [];
  const engine = createHookEngine({
    sandbox: fs.sandbox,
    sources: [staticSource(hooks)],
    promptEvaluator: async () => null,
    onNotification: (message, ctx) => notifications.push({ message, ...ctx }),
    ...extra,
  });
  return { engine, notifications };
}

// ---------------------------------------------------------------------------
// stdin + env contract (hook_stdin_test.dart)
// ---------------------------------------------------------------------------

describe("command hook stdin/env contract", () => {
  it("delivers the full CC stdin JSON and the four OVID_HOOK_* env vars", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", matcher: "*", command: "true" }),
    ], { secrets: () => ["sk-secret-value"] });

    await engine.fireGate("s1", {
      tool: "run_shell",
      args: { command: "echo hi", api_key: "sk-secret-value" },
    });

    expect(fs.execCalls).toHaveLength(1);
    const call = fs.execCalls[0]!;
    const env = call.o.env!;
    expect(env.OVID_HOOK_EVENT).toBe("pre_tool");
    expect(env.OVID_HOOK_PLUGIN).toBe("plugin-a");
    expect(env.OVID_HOOK_SESSION).toBe("s1");
    expect(env.OVID_HOOK_PAYLOAD).toContain("[REDACTED]");
    expect(env.OVID_HOOK_PAYLOAD).not.toContain("sk-secret-value");
    // [CC] canonical spellings.
    expect(env.PLUGIN_EVENT).toBe("pre_tool");
    expect(env.PLUGIN_SESSION).toBe("s1");
    expect(env.CLAUDE_PROJECT_DIR).toBe("/workspace");
    expect(env.CLAUDE_CODE_REMOTE).toBe("");

    const stdin = JSON.parse(decodeStdin(call.o.cmd)) as Record<string, unknown>;
    expect(stdin["session_id"]).toBe("s1");
    expect(stdin["hook_event_name"]).toBe("PreToolUse");
    expect(stdin["tool_name"]).toBe("Bash");
    expect(stdin["ovid_tool_name"]).toBe("run_shell");
    expect(stdin["tool_input"]).toMatchObject({ command: "echo hi" });
    expect(stdin["permission_mode"]).toBe("");
    expect(stdin["cwd"]).toBe("/workspace");
    expect(stdin["transcript_path"]).toBe("");
    // Absent optionals are OMITTED, not null.
    expect("tool_response" in stdin).toBe(false);
    expect("prompt" in stdin).toBe(false);
    // Redaction applied before serialization.
    expect(JSON.stringify(stdin)).not.toContain("sk-secret-value");
  });

  it("flows transcript_path from the payload and carries prompt without tool keys", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "user_prompt_submit", command: "true" }),
    ]);

    await engine.fireDetailed("user_prompt_submit", "s1", {
      prompt: "hello",
      transcript_path: "/tmp/t.jsonl",
    });

    const stdin = JSON.parse(decodeStdin(fs.execCalls[0]!.o.cmd)) as Record<string, unknown>;
    expect(stdin["hook_event_name"]).toBe("UserPromptSubmit");
    expect(stdin["prompt"]).toBe("hello");
    expect(stdin["transcript_path"]).toBe("/tmp/t.jsonl");
    expect("tool_name" in stdin).toBe(false);
    expect("tool_input" in stdin).toBe(false);
  });

  it("sends PostToolUseFailure for a failed post_tool and bounds the env tool_response", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "post_tool", command: "true" }),
    ]);
    const big = "x".repeat(5000);
    await engine.fire("post_tool", "s1", {
      tool: "run_shell",
      result: big,
      ok: false,
    });

    const call = fs.execCalls[0]!;
    const stdin = JSON.parse(decodeStdin(call.o.cmd)) as Record<string, unknown>;
    expect(stdin["hook_event_name"]).toBe("PostToolUseFailure");
    // stdin is untruncated.
    expect((stdin["tool_response"] as string).length).toBe(5000);
    // the env copy is bounded at 4000 + ellipsis.
    expect(call.o.env!.OVID_HOOK_PAYLOAD).not.toContain("x".repeat(4001));
    expect(call.o.env!.OVID_HOOK_PAYLOAD).toContain("…");
  });
});

// ---------------------------------------------------------------------------
// Matcher parity (hook_matcher_parity_test.dart)
// ---------------------------------------------------------------------------

describe("matcher parity", () => {
  it("matches Bash for run_shell and Edit* for fs_edit", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ id: "bash", event: "pre_tool", matcher: "Bash", command: "true" }),
      def({ id: "edit", event: "pre_tool", matcher: "Edit*", command: "true" }),
    ]);

    await engine.fireGate("s1", { tool: "run_shell", args: { command: "ls" } });
    await engine.fireGate("s1", {
      tool: "fs_edit",
      args: { command: "str_replace", path: "a.txt" },
    });

    expect(fs.execCalls).toHaveLength(2);
    expect(fs.execCalls[0]!.o.env!.OVID_HOOK_EVENT).toBe("pre_tool");
  });

  it("does not execute a non-matching hook", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", matcher: "Bash", command: "true" }),
    ]);

    const result = await engine.fireGate("s1", { tool: "file_read", args: {} });
    expect(result.decision).toBe("allow");
    expect(fs.execCalls).toHaveLength(0);
  });

  it("anchors exact names: Edit does not match MultiEdit", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", matcher: "Edit", command: "true" }),
    ]);

    await engine.fireGate("s1", { tool: "multi_edit", args: {} });
    expect(fs.execCalls).toHaveLength(0);
  });

  it("supports alternation, wildcard, empty, and Task for dispatch_agent", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ id: "alt", event: "pre_tool", matcher: "Read|Write", command: "true" }),
      def({ id: "all", event: "pre_tool", matcher: "*", command: "true" }),
      def({ id: "empty", event: "pre_tool", command: "true" }),
      def({ id: "task", event: "pre_tool", matcher: "Task", command: "true" }),
    ]);

    await engine.fireGate("s1", { tool: "dispatch_agent", args: { label: "x" } });
    // alt does not match; the other three do.
    expect(fs.execCalls).toHaveLength(3);
  });

  it("session_start matches the source token (startup default)", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "session_start", matcher: "startup|clear|compact", command: "true" }),
    ]);

    await engine.fireDetailed("session_start", "s1", {});
    expect(fs.execCalls).toHaveLength(1);
  });

  it("matches an MCP server prefix boundary-exactly", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", matcher: "mcp__github", command: "true" }),
    ]);

    await engine.fireGate("s1", { tool: "mcp__github__create_issue", args: {} });
    await engine.fireGate("s1", { tool: "mcp__githubv2__x", args: {} });
    await engine.fireGate("s1", { tool: "mcp__git__x", args: {} });
    expect(fs.execCalls).toHaveLength(1);
  });

  it("rejects unsafe/oversized matchers instead of compiling them", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ id: "long", event: "pre_tool", matcher: "a".repeat(5000), command: "true" }),
      def({ id: "redos", event: "pre_tool", matcher: "(a+)+$", command: "true" }),
      def({ id: "redos2", event: "pre_tool", matcher: "(.*)*", command: "true" }),
    ]);

    await engine.fireGate("s1", { tool: "Bash", args: {} });
    expect(fs.execCalls).toHaveLength(0);
  });

  it("ignores a matcher on events with no matcher vocabulary", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "notification", matcher: "does-not-match", command: "true" }),
      def({ event: "stop", matcher: "does-not-match", command: "true" }),
    ]);

    await engine.fireDetailed("notification", "s1", { message: "hi" });
    await engine.fireStop("s1", {});
    expect(fs.execCalls).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------
// Gate semantics (hook_allow_bypass_test.dart, gate contract)
// ---------------------------------------------------------------------------

describe("fireGate", () => {
  it("exit 2 denies with stderr as the reason", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 2, stdout: "", stderr: "no writes today" }));
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", command: "guard" }),
    ]);

    const result = await engine.fireGate("s1", { tool: "file_write", args: {} });
    expect(result.decision).toBe("deny");
    expect(result.reason).toBe("no writes today");
    expect(result.deniedByPlugin).toBe("plugin-a");
  });

  it("JSON decision block denies; decision is parsed from RAW stdout", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(JSON.stringify({ decision: "block", reason: "not allowed" })),
    );
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", command: "guard" }),
    ]);

    const result = await engine.fireGate("s1", { tool: "file_write", args: {} });
    expect(result.decision).toBe("deny");
    expect(result.reason).toBe("not allowed");
  });

  it("permissionDecision allow yields bypassPermission and updatedInput", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(
        JSON.stringify({
          hookSpecificOutput: {
            permissionDecision: "allow",
            updatedInput: { file_path: "/workspace/x.txt", content: "hi" },
          },
        }),
      ),
    );
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", matcher: "Write", command: "rewrite" }),
    ]);

    const result = await engine.fireGate("s1", {
      tool: "file_write",
      args: { path: "/tmp/x.txt" },
    });
    expect(result.decision).toBe("allow");
    expect(result.bypassPermission).toBe(true);
    // CC `file_path` translated back to native `path`.
    expect(result.updatedInput).toMatchObject({
      path: "/workspace/x.txt",
      content: "hi",
    });
  });

  it("deny and ask still win over an allow from another hook", async () => {
    const fs = fakeSandbox();
    let n = 0;
    fs.setHandler(() => {
      n += 1;
      return n === 1
        ? ok(JSON.stringify({ hookSpecificOutput: { permissionDecision: "allow" } }))
        : ok(JSON.stringify({ decision: "deny", reason: "nope" }));
    });
    const { engine } = makeEngine(fs, [
      def({ id: "allow", event: "pre_tool", command: "a" }),
      def({ id: "deny", event: "pre_tool", command: "b" }),
    ]);

    const result = await engine.fireGate("s1", { tool: "Bash", args: {} });
    expect(result.decision).toBe("deny");
    expect(result.reason).toBe("nope");
  });

  it("permissionDecision ask surfaces as ask", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(
        JSON.stringify({
          hookSpecificOutput: {
            permissionDecision: "ask",
            permissionDecisionReason: "check this",
          },
        }),
      ),
    );
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", command: "ask" }),
    ]);

    const result = await engine.fireGate("s1", { tool: "Bash", args: {} });
    expect(result.decision).toBe("ask");
    expect(result.reason).toBe("check this");
  });

  it("a PermissionRequest envelope cannot approve a PreToolUse gate", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(
        JSON.stringify({
          hookSpecificOutput: {
            hookEventName: "PermissionRequest",
            decision: { behavior: "allow", updatedInput: { path: "/evil" } },
          },
        }),
      ),
    );
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", command: "old-plugin" }),
    ]);

    const result = await engine.fireGate("s1", { tool: "file_write", args: {} });
    expect(result.decision).toBe("allow");
    expect(result.bypassPermission).toBeUndefined();
    expect(result.updatedInput).toBeUndefined();
  });

  it("continue:false halts later hooks", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok(JSON.stringify({ continue: false })));
    const { engine } = makeEngine(fs, [
      def({ id: "one", event: "pre_tool", command: "a" }),
      def({ id: "two", event: "pre_tool", command: "b" }),
    ]);

    await engine.fireGate("s1", { tool: "Bash", args: {} });
    expect(fs.execCalls).toHaveLength(1);
  });

  it("fails OPEN on a non-2 nonzero exit", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 1, stdout: "", stderr: "boom" }));
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", command: "broken" }),
    ]);

    const result = await engine.fireGate("s1", { tool: "Bash", args: {} });
    expect(result.decision).toBe("allow");
  });

  it("does not turn a secret equal to a decision word into an allow", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(JSON.stringify({ decision: "block", reason: "deny" })),
    );
    const { engine } = makeEngine(
      fs,
      [def({ event: "pre_tool", command: "guard" })],
      { secrets: () => ["deny"] },
    );

    const result = await engine.fireGate("s1", {
      tool: "Bash",
      args: { token: "deny" },
    });
    expect(result.decision).toBe("deny");
    expect(result.reason).toBe("[REDACTED]");
  });
});

// ---------------------------------------------------------------------------
// Stop semantics
// ---------------------------------------------------------------------------

describe("fireStop", () => {
  it("exit 2 vetoes with stderr as the reason", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 2, stdout: "", stderr: "keep working" }));
    const { engine } = makeEngine(fs, [
      def({ event: "stop", command: "guard" }),
    ]);

    const result = await engine.fireStop("s1", {});
    expect(result).toEqual({
      veto: true,
      reason: "keep working",
      vetoedByPlugin: "plugin-a",
    });
  });

  it("a user-initiated stop always wins without running hooks", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 2, stdout: "", stderr: "veto" }));
    const { engine } = makeEngine(fs, [
      def({ event: "stop", command: "guard" }),
    ]);

    const result = await engine.fireStop("s1", { userStopRequested: true });
    expect(result).toEqual({ veto: false });
    expect(fs.execCalls).toHaveLength(0);
  });

  it("ask is meaningless at stop time and allows", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(JSON.stringify({ hookSpecificOutput: { permissionDecision: "ask" } })),
    );
    const { engine } = makeEngine(fs, [
      def({ event: "stop", command: "guard" }),
    ]);

    const result = await engine.fireStop("s1", {});
    expect(result).toEqual({ veto: false });
  });

  it("subagent_stop also vetoes", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 2, stdout: "", stderr: "child continues" }));
    const { engine } = makeEngine(fs, [
      def({ event: "subagent_stop", command: "guard" }),
    ]);

    const result = await engine.fireStop("s1", {}, "subagent_stop");
    expect(result.veto).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Observe semantics (context injection)
// ---------------------------------------------------------------------------

describe("observe events", () => {
  it("pre_request stdout becomes fireDetailed().output", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok("remember the lint rules"));
    const { engine } = makeEngine(fs, [
      def({ event: "pre_request", command: "ctx" }),
    ]);

    const result = await engine.fireDetailed("pre_request", "s1", { turn: 0 });
    expect(result.output).toBe("remember the lint rules");
    expect(result.promptBlockReason).toBeNull();
  });

  it("session_start stdout becomes the standing sessionContextFor", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok("session context here"));
    const { engine } = makeEngine(fs, [
      def({ event: "session_start", command: "ctx" }),
    ]);

    await engine.fire("session_start", "s1", {});
    expect(engine.sessionContextFor("s1")).toBe("session context here");
    // Another session is isolated.
    expect(engine.sessionContextFor("s2")).toBe("");
  });

  it("user_prompt_submit stdout becomes the standing promptContextFor", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok("prompt context"));
    const { engine } = makeEngine(fs, [
      def({ event: "user_prompt_submit", command: "ctx" }),
    ]);

    await engine.fireDetailed("user_prompt_submit", "s1", { prompt: "hi" });
    expect(engine.promptContextFor("s1")).toBe("prompt context");
  });

  it("extracts additionalContext without leaking the JSON envelope", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(
        JSON.stringify({
          hookSpecificOutput: { additionalContext: "injected skill intro" },
        }),
      ),
    );
    const { engine } = makeEngine(fs, [
      def({ event: "session_start", command: "superpowers" }),
    ]);

    await engine.fire("session_start", "s1", {});
    expect(engine.sessionContextFor("s1")).toBe("injected skill intro");
    expect(engine.sessionContextFor("s1")).not.toContain("hookSpecificOutput");
  });

  it("surfaces systemMessage and honors suppressOutput", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(JSON.stringify({ systemMessage: "note", suppressOutput: true })),
    );
    const { engine } = makeEngine(fs, [
      def({ event: "pre_request", command: "ctx" }),
    ]);

    const result = await engine.fireDetailed("pre_request", "s1", {});
    expect(result.systemMessages).toEqual(["note"]);
    expect(result.output).toBe("");
  });

  it("exit 2 on user_prompt_submit becomes promptBlockReason", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 2, stdout: "", stderr: "blocked prompt" }));
    const { engine } = makeEngine(fs, [
      def({ event: "user_prompt_submit", command: "guard" }),
    ]);

    const result = await engine.fireDetailed("user_prompt_submit", "s1", {
      prompt: "do it",
    });
    expect(result.promptBlockReason).toBe("blocked prompt");
  });

  it("exit 2 on post_tool is feedback, not a breaker failure", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 2, stdout: "", stderr: "feedback" }));
    const { engine, notifications } = makeEngine(fs, [
      def({ event: "post_tool", command: "guard" }),
    ]);

    for (let i = 0; i < 4; i += 1) {
      await engine.fireDetailed("post_tool", "s1", { tool: "Bash", ok: true });
    }
    expect(fs.execCalls).toHaveLength(4);
    expect(notifications).toHaveLength(0);
  });

  it("caps pre_request output at 2048 chars", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok("y".repeat(3000)));
    const { engine } = makeEngine(fs, [
      def({ event: "pre_request", command: "ctx" }),
    ]);

    const result = await engine.fireDetailed("pre_request", "s1", {});
    expect(result.output.length).toBe(2048);
  });
});

// ---------------------------------------------------------------------------
// Circuit breaker (hook_blocker_diagnostics_test.dart, hook_w07_test.dart)
// ---------------------------------------------------------------------------

describe("circuit breaker", () => {
  it("trips after 3 consecutive failures and skips the 4th with a notification", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 1, stdout: "", stderr: "broken" }));
    const { engine, notifications } = makeEngine(fs, [
      def({ event: "pre_request", command: "broken" }),
    ]);

    for (let i = 0; i < 4; i += 1) {
      await engine.fireDetailed("pre_request", "s1", {});
    }

    expect(fs.execCalls).toHaveLength(HOOK_BREAKER_THRESHOLD);
    expect(notifications).toHaveLength(1);
    expect(notifications[0]!.message).toContain("circuit breaker");
    expect(notifications[0]!.message).toContain("re-enable the plugin to retry");
    expect(await engine.hasListeners("pre_request", "s1")).toBe(false);
  });

  it("a success between failures resets the counter", async () => {
    const fs = fakeSandbox();
    let n = 0;
    fs.setHandler(() => {
      n += 1;
      return n === 3 ? ok("fine") : { exitCode: 1, stdout: "", stderr: "x" };
    });
    const { engine, notifications } = makeEngine(fs, [
      def({ event: "pre_request", command: "flaky" }),
    ]);

    for (let i = 0; i < 5; i += 1) {
      await engine.fireDetailed("pre_request", "s1", {});
    }
    // fail, fail, success, fail, fail — never three in a row.
    expect(fs.execCalls).toHaveLength(5);
    expect(notifications).toHaveLength(0);
  });

  it("spawn/runtime failures stay retryable and never consume the breaker", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => {
      throw new Error("spawn ENOENT");
    });
    const { engine, notifications } = makeEngine(fs, [
      def({ event: "pre_request", command: "missing" }),
    ]);

    for (let i = 0; i < 6; i += 1) {
      await engine.fireDetailed("pre_request", "s1", {});
    }
    expect(fs.execCalls).toHaveLength(6);
    expect(notifications).toHaveLength(0);
  });

  it("exit 126/127 stays retryable", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 127, stdout: "", stderr: "not found" }));
    const { engine, notifications } = makeEngine(fs, [
      def({ event: "pre_request", command: "missing" }),
    ]);

    for (let i = 0; i < 5; i += 1) {
      await engine.fireDetailed("pre_request", "s1", {});
    }
    expect(fs.execCalls).toHaveLength(5);
    expect(notifications).toHaveLength(0);
  });

  it("session_start failures never consume the breaker", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ({ exitCode: 1, stdout: "", stderr: "boom" }));
    const { engine, notifications } = makeEngine(fs, [
      def({ event: "session_start", command: "broken" }),
    ]);

    for (let i = 0; i < 5; i += 1) {
      await engine.fireDetailed("session_start", "s1", {});
    }
    expect(fs.execCalls).toHaveLength(5);
    expect(notifications).toHaveLength(0);
  });

  it("oversized output fails open and kills the child", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok("z".repeat(70_000)));
    const { engine } = makeEngine(fs, [
      def({ event: "pre_request", command: "chatty" }),
    ]);

    const result = await engine.fireDetailed("pre_request", "s1", {});
    expect(result.output).toBe("");
    expect(fs.kills).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------
// Prompt hooks
// ---------------------------------------------------------------------------

describe("prompt hooks", () => {
  it("parsePromptHookDecision accepts JSON and plain-text verdicts", () => {
    expect(parsePromptHookDecision(JSON.stringify({ decision: "block", reason: "no" }))).toEqual({
      decision: "block",
      reason: "no",
    });
    expect(parsePromptHookDecision(JSON.stringify({ decision: "approve" }))).toEqual({
      decision: "approve",
      reason: null,
    });
    expect(parsePromptHookDecision(JSON.stringify({ ok: false, reason: "bad" }))).toEqual({
      decision: "block",
      reason: "bad",
    });
    expect(parsePromptHookDecision("block because reasons").decision).toBe("block");
    expect(parsePromptHookDecision("approve").decision).toBe("approve");
    expect(parsePromptHookDecision("do not block this").decision).toBeNull();
    expect(parsePromptHookDecision("garbage").decision).toBeNull();
    expect(parsePromptHookDecision("")).toEqual({ decision: null, reason: null });
    expect(parsePromptHookDecision(null)).toEqual({ decision: null, reason: null });
  });

  it("a prompt block on pre_tool denies the gate", async () => {
    const fs = fakeSandbox();
    let promptSeen = "";
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", type: "prompt", prompt: "never rm -rf" }),
    ], {
      promptEvaluator: async (prompt) => {
        promptSeen = prompt;
        return JSON.stringify({ decision: "block", reason: "destructive" });
      },
    });

    const result = await engine.fireGate("s1", { tool: "run_shell", args: { command: "rm -rf /" } });
    expect(result.decision).toBe("deny");
    expect(result.reason).toBe("destructive");
    expect(promptSeen).toContain("never rm -rf");
    expect(promptSeen).toContain("PreToolUse");
    expect(promptSeen).toContain("rm -rf /");
    expect(fs.execCalls).toHaveLength(0);
  });

  it("a prompt block on an observe event surfaces promptBlockReason but cannot halt", async () => {
    const { engine } = makeEngine(
      fakeSandbox(),
      [def({ event: "pre_request", type: "prompt", prompt: "rule" })],
      { promptEvaluator: async () => "block" },
    );

    const result = await engine.fireDetailed("pre_request", "s1", {});
    expect(result.promptBlockReason).toBe("block");
  });

  it("a throwing evaluator fails open", async () => {
    const { engine } = makeEngine(
      fakeSandbox(),
      [def({ event: "pre_tool", type: "prompt", prompt: "rule" })],
      {
        promptEvaluator: async () => {
          throw new Error("model down");
        },
      },
    );

    const result = await engine.fireGate("s1", { tool: "Bash", args: {} });
    expect(result.decision).toBe("allow");
  });

  it("prompt hooks are skipped on events with no prompt support", async () => {
    let calls = 0;
    const { engine } = makeEngine(
      fakeSandbox(),
      [def({ event: "pre_request", type: "prompt", prompt: "rule" })],
      {
        promptEvaluator: async () => {
          calls += 1;
          return "block";
        },
      },
    );
    // pre_request IS supported in the cloud (observe); notification is not.
    await engine.fireDetailed("notification", "s1", { message: "x" });
    expect(calls).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Serialization (parallel_hooks_contract_test.dart)
// ---------------------------------------------------------------------------

describe("per-session serialization", () => {
  it("serializes concurrent fireGate calls for one session", async () => {
    const fs = fakeSandbox();
    let active = 0;
    let maxActive = 0;
    const order: string[] = [];
    fs.setHandler(async () => {
      active += 1;
      maxActive = Math.max(maxActive, active);
      order.push("start");
      await new Promise((r) => setTimeout(r, 10));
      order.push("end");
      active -= 1;
      return ok();
    });
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", command: "guard" }),
    ]);

    await Promise.all([
      engine.fireGate("s1", { tool: "Bash", args: { n: 1 } }),
      engine.fireGate("s1", { tool: "Bash", args: { n: 2 } }),
    ]);

    expect(maxActive).toBe(1);
    expect(order).toEqual(["start", "end", "start", "end"]);
  });

  it("lets observe events overlap", async () => {
    const fs = fakeSandbox();
    let active = 0;
    let maxActive = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    fs.setHandler(async () => {
      active += 1;
      maxActive = Math.max(maxActive, active);
      await gate;
      active -= 1;
      return ok();
    });
    const { engine } = makeEngine(fs, [
      def({ event: "pre_request", command: "observe" }),
    ]);

    const both = Promise.all([
      engine.fireDetailed("pre_request", "s1", { turn: 0 }),
      engine.fireDetailed("pre_request", "s1", { turn: 1 }),
    ]);
    await new Promise((r) => setTimeout(r, 10));
    expect(maxActive).toBe(2);
    release();
    await both;
  });
});

// ---------------------------------------------------------------------------
// Redaction (hook_security_test.dart, parallel redaction split)
// ---------------------------------------------------------------------------

describe("redactHookPayload", () => {
  it("redacts secret-named keys recursively, including lists", () => {
    const out = redactHookPayload(
      {
        args: { api_key: "sk-1", headers: { Authorization: "Bearer x" }, password: "p" },
        token: "t",
        list: [{ secret: "s" }, { keep: "visible" }],
        safe: "unchanged",
      },
      [],
    );
    expect(out).toEqual({
      args: { api_key: "[REDACTED]", headers: { Authorization: "[REDACTED]" }, password: "[REDACTED]" },
      token: "[REDACTED]",
      list: [{ secret: "[REDACTED]" }, { keep: "visible" }],
      safe: "unchanged",
    });
  });

  it("replaces exact secret substrings everywhere", () => {
    const out = redactHookPayload(
      { command: "curl -H 'Authorization: Bearer sk-live-123'", nested: { note: "sk-live-123" } },
      ["sk-live-123"],
    );
    expect(JSON.stringify(out)).not.toContain("sk-live-123");
    expect(JSON.stringify(out)).toContain("[REDACTED]");
  });
});

// ---------------------------------------------------------------------------
// CC payload shaping (claude_code_hooks_mcp_parity_test.dart:67/316)
// ---------------------------------------------------------------------------

describe("CC payload shaping", () => {
  it("ccToolInput keeps native keys and adds CC aliases", () => {
    expect(
      ccToolInput("fs_edit", {
        command: "str_replace",
        path: "/w/a.txt",
        old_str: "a",
        new_str: "b",
      }),
    ).toEqual({
      command: "str_replace",
      path: "/w/a.txt",
      old_str: "a",
      new_str: "b",
      file_path: "/w/a.txt",
      old_string: "a",
      new_string: "b",
      replace_all: false,
    });
  });

  it("nativeToolInput translates CC rewrites back and drops replace_all", () => {
    expect(
      nativeToolInput(
        "fs_edit",
        { command: "str_replace", path: "/w/a.txt" },
        {
          file_path: "/w/b.txt",
          old_string: "x",
          new_string: "y",
          replace_all: true,
        },
      ),
    ).toEqual({ path: "/w/b.txt", old_str: "x", new_str: "y" });
  });

  it("nativeToolInput maps create content to file_text", () => {
    expect(
      nativeToolInput(
        "fs_edit",
        { command: "create" },
        { file_path: "/w/new.txt", content: "hello" },
      ),
    ).toEqual({ path: "/w/new.txt", file_text: "hello" });
  });
});

// ---------------------------------------------------------------------------
// Listener/diagnostic helpers
// ---------------------------------------------------------------------------

describe("hasListeners and output contract", () => {
  it("reports listeners only for events with non-tripped hooks", async () => {
    const fs = fakeSandbox();
    const { engine } = makeEngine(fs, [
      def({ event: "pre_tool", command: "true" }),
    ]);
    expect(await engine.hasListeners("pre_tool", "s1")).toBe(true);
    expect(await engine.hasListeners("post_tool", "s1")).toBe(false);
  });

  it("continue:false halts later observe hooks", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok(JSON.stringify({ continue: false })));
    const { engine } = makeEngine(fs, [
      def({ id: "one", event: "pre_request", command: "a" }),
      def({ id: "two", event: "pre_request", command: "b" }),
    ]);

    await engine.fireDetailed("pre_request", "s1", {});
    expect(fs.execCalls).toHaveLength(1);
  });

  it("scrubs secret values from system messages and context", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() =>
      ok(JSON.stringify({ systemMessage: "leak sk-secret", additionalContext: "ctx sk-secret" })),
    );
    const { engine } = makeEngine(
      fs,
      [def({ event: "pre_request", command: "ctx" })],
      { secrets: () => ["sk-secret"] },
    );

    const result = await engine.fireDetailed("pre_request", "s1", {});
    expect(result.output).toBe("ctx [REDACTED]");
    expect(result.systemMessages).toEqual(["leak [REDACTED]"]);
  });

  it("caps standing session context at 8192", async () => {
    const fs = fakeSandbox();
    fs.setHandler(() => ok("q".repeat(9000)));
    const { engine } = makeEngine(fs, [
      def({ event: "session_start", command: "ctx" }),
    ]);

    await engine.fire("session_start", "s1", {});
    expect(engine.sessionContextFor("s1").length).toBe(8192);
    expect(engine.sessionContextFor("s1")).toContain("[hook output truncated]");
  });
});

// ---------------------------------------------------------------------------
// File source (.dsh/hooks.json)
// ---------------------------------------------------------------------------

describe("createFileHookSource", () => {
  it("reads .dsh/hooks.json, normalizes aliases, and skips unsupported types", async () => {
    const fs = fakeSandbox();
    fs.files.set(
      ".dsh/hooks.json",
      JSON.stringify([
        { event: "PreToolUse", matcher: "Bash", command: "echo hi", id: "cc" },
        { event: "on_turn_end", type: "prompt", prompt: "rule" },
        { event: "agent", type: "agent", prompt: "nope" },
        { event: "session_end", command: "nope" },
      ]),
    );
    const source = createFileHookSource({ sandbox: fs.sandbox });

    const hooks = await source.hooksFor("s1");
    expect(hooks.map((h) => h.event)).toEqual(["pre_tool", "stop"]);
    expect(hooks[0]!.id).toBe("cc");
    expect(hooks[0]!.type).toBe("command");
    expect(hooks[1]!.type).toBe("prompt");
  });

  it("returns [] for a missing or malformed file", async () => {
    const fs = fakeSandbox();
    const source = createFileHookSource({ sandbox: fs.sandbox });
    expect(await source.hooksFor("s1")).toEqual([]);

    fs.files.set(".dsh/hooks.json", "{not json");
    expect(await source.hooksFor("s1")).toEqual([]);
  });
});
