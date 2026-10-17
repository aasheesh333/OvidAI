import { describe, expect, it } from "vitest";

import { CC_TO_NATIVE, ccToolName, nativeToolsFor } from "./claudeCodeTools.js";

// The full table from lib/core/claude_code_tools.dart `_ccToNative` — the
// contract, entry for entry.
const DART_TABLE: Record<string, string[]> = {
  Bash: ["run_shell", "job_start", "job_output", "job_list", "job_kill"],
  PowerShell: ["run_shell"],
  Read: ["file_read", "read_image", "read_attachment"],
  Write: ["file_write"],
  Edit: ["fs_edit"],
  MultiEdit: ["multi_edit"],
  NotebookEdit: ["notebook_edit"],
  NotebookRead: ["file_read"],
  Glob: ["fs_glob"],
  LS: ["fs_glob"],
  Grep: ["fs_grep"],
  WebFetch: ["fetch_url"],
  WebSearch: ["web_search"],
  Agent: ["dispatch_agent"],
  Task: ["dispatch_agent"],
  Workflow: ["workflow"],
  TodoWrite: ["todo_write"],
  Skill: ["skill"],
  AskUserQuestion: ["ask_user_question"],
  ExitPlanMode: ["exit_plan_mode"],
  SendMessage: ["send_message"],
  TaskStop: ["interrupt_agent"],
  TaskOutput: ["job_output"],
};

describe("CC_TO_NATIVE (exact port of claude_code_tools.dart)", () => {
  it("carries every Dart entry with the same native grants", () => {
    expect({ ...CC_TO_NATIVE }).toEqual(DART_TABLE);
  });

  it("Bash expands to the full shell/job family in the pinned order", () => {
    expect(CC_TO_NATIVE.Bash).toEqual([
      "run_shell",
      "job_start",
      "job_output",
      "job_list",
      "job_kill",
    ]);
  });
});

describe("ccToolName", () => {
  it("maps native tools to the CC name a matcher/stdin sees", () => {
    expect(ccToolName("fs_edit")).toBe("Edit");
    expect(ccToolName("run_shell")).toBe("Bash");
    expect(ccToolName("job_start")).toBe("Bash");
    expect(ccToolName("file_read")).toBe("Read");
    expect(ccToolName("read_image")).toBe("Read");
    expect(ccToolName("file_write")).toBe("Write");
    expect(ccToolName("multi_edit")).toBe("MultiEdit");
    expect(ccToolName("notebook_edit")).toBe("NotebookEdit");
    expect(ccToolName("fs_glob")).toBe("Glob");
    expect(ccToolName("fs_grep")).toBe("Grep");
    expect(ccToolName("fetch_url")).toBe("WebFetch");
    expect(ccToolName("web_search")).toBe("WebSearch");
    expect(ccToolName("dispatch_agent")).toBe("Agent");
    expect(ccToolName("workflow")).toBe("Workflow");
    expect(ccToolName("todo_write")).toBe("TodoWrite");
    expect(ccToolName("skill")).toBe("Skill");
    expect(ccToolName("ask_user_question")).toBe("AskUserQuestion");
    expect(ccToolName("exit_plan_mode")).toBe("ExitPlanMode");
    expect(ccToolName("send_message")).toBe("SendMessage");
    expect(ccToolName("interrupt_agent")).toBe("TaskStop");
  });

  it("resolves fs_edit per operation (CC's own create-vs-edit split)", () => {
    expect(ccToolName("fs_edit", { command: "view" })).toBe("Read");
    expect(ccToolName("fs_edit", { command: "create" })).toBe("Write");
    expect(ccToolName("fs_edit", { command: "str_replace" })).toBe("Edit");
  });

  it("returns the native name itself when there is no CC equivalent", () => {
    // Dart returns null and every caller falls back to the native name (MCP
    // tools keep their mcp__server__tool name, which already IS the CC name);
    // the TS signature folds that fallback into the function.
    expect(ccToolName("mcp__s__t")).toBe("mcp__s__t");
    expect(ccToolName("render_html")).toBe("render_html");
  });
});

describe("nativeToolsFor", () => {
  it("expands a CC name to its native tools", () => {
    expect(nativeToolsFor("Edit")).toEqual(["fs_edit"]);
    expect(nativeToolsFor("Read")).toEqual(["file_read", "read_image", "read_attachment"]);
    expect(nativeToolsFor("Task")).toEqual(["dispatch_agent"]);
    expect(nativeToolsFor("TodoWrite")).toEqual(["todo_write"]);
  });

  it("a permission-rule specifier scopes the WHOLE tool (CC rule)", () => {
    expect(nativeToolsFor("Bash(git push *)")).toEqual([
      "run_shell",
      "job_start",
      "job_output",
      "job_list",
      "job_kill",
    ]);
    expect(nativeToolsFor("Read(foo.dart)")).toEqual([
      "file_read",
      "read_image",
      "read_attachment",
    ]);
  });

  it("expands MCP patterns", () => {
    // `mcp__<server>` (no tool segment) grants the whole server.
    expect(nativeToolsFor("mcp__srv")).toEqual(["mcp__srv__*"]);
    // Explicit wildcards pass through as patterns.
    expect(nativeToolsFor("mcp__srv__*")).toEqual(["mcp__srv__*"]);
    expect(nativeToolsFor("mcp__*")).toEqual(["mcp__*"]);
    // An exact MCP tool grant stays exact.
    expect(nativeToolsFor("mcp__srv__ping")).toEqual(["mcp__srv__ping"]);
  });

  it("passes prefix patterns and bare wildcards through", () => {
    expect(nativeToolsFor("*")).toEqual(["*"]);
    expect(nativeToolsFor("fs_*")).toEqual(["fs_*"]);
  });

  it("a native name grants itself", () => {
    expect(nativeToolsFor("fs_edit")).toEqual(["fs_edit"]);
    expect(nativeToolsFor("plugin__x__y")).toEqual(["plugin__x__y"]);
  });
});
