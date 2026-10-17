import { describe, expect, it } from "vitest";

import {
  HARNESS_TOOLS,
  PLAN_ALLOWED_TOOLS,
  PLAN_HARD_DENIED_PREFIXES,
} from "./planMode.js";

// The Dart allowlist (lib/core/plan_mode.dart PlanModePolicy.allowedTools),
// transcribed member for member — it is the contract.
const DART_ALLOWLIST: ReadonlySet<string> = new Set([
  // ── reading the workspace ────────────────────────────────────────
  "file_read",
  "fs_view",
  "fs_glob",
  "fs_grep",
  "view",
  "read_attachment",
  "read_image",
  // ── reading repo state (GitHub API + local git) ──────────────────
  "repo_read",
  "repo_tree",
  "git_status",
  "git_log",
  "git_diff",
  // ── inspecting the workspace with the shell (opencode parity) ────
  "run_shell",
  // ── research ─────────────────────────────────────────────────────
  "fetch_url",
  "web_search",
  "memory_search",
  "memory_read",
  "session_search",
  "session_read",
  // ── reading the browser WITHOUT driving it ───────────────────────
  "browser_read",
  "browser_list_tabs",
  "browser_find",
  "browser_wait_for",
  "browser_snapshot",
  "browser_outline",
  "browser_screenshot",
  // ── reading background state ─────────────────────────────────────
  "job_list",
  "job_output",
  "get_goal",
  "schedule_list",
  "catalog_get_provider",
  "catalog_list_mcp",
  "catalog_list_models",
  "catalog_list_plugins",
  "catalog_list_providers",
  // ── planning itself ──────────────────────────────────────────────
  "todo_write",
  "ask_user_question",
  "exit_plan_mode",
  "list_agents",
  "report",
  "skill",
]);

describe("PLAN_ALLOWED_TOOLS (exact port of plan_mode.dart)", () => {
  it("is exactly the Dart allowlist, member for member", () => {
    expect(new Set(PLAN_ALLOWED_TOOLS)).toEqual(DART_ALLOWLIST);
  });

  it("admits the research and planning tools", () => {
    // One by one, so a failure names the tool that fell off the allowlist.
    for (const t of [
      "run_shell",
      "file_read",
      "fs_grep",
      "fs_glob",
      "git_log",
      "git_status",
      "git_diff",
      "todo_write",
      "ask_user_question",
      "exit_plan_mode",
      "browser_screenshot",
      "memory_search",
      "session_search",
      "job_list",
      "schedule_list",
      "catalog_list_models",
      "list_agents",
      "report",
      "skill",
    ]) {
      expect(PLAN_ALLOWED_TOOLS.has(t), t).toBe(true);
    }
  });

  it("default-denies every mutating core tool (the blocklist escapes stay out)", () => {
    for (const t of [
      "file_write",
      "fs_edit",
      "commit",
      "run_code",
      "repo_sync",
      "git_push",
      "job_start",
      "preview",
      "generate_image",
      "edit_image",
      "resize_image",
      "crop_image",
      // the browser drivers the old blocklist missed
      "browser_open",
      "browser_navigate",
      "browser_new_tab",
      "browser_close_tab",
      "browser_switch_tab",
      "browser_back",
      "browser_forward",
      "browser_reload",
      "browser_resize",
      "browser_scroll",
      "browser_hover",
      "browser_click",
      "browser_type",
      "browser_evaluate",
      // acting through another session
      "interrupt_agent",
      "send_message",
      // an unknown or future tool
      "some_tool_added_next_release",
    ]) {
      expect(PLAN_ALLOWED_TOOLS.has(t), `${t} must stay refused`).toBe(false);
    }
  });

  it("never admits device / plugin / MCP tools", () => {
    for (const t of ["device_tap", "device_read", "device_type", "plugin__x__y", "mcp__s__t"]) {
      expect(PLAN_ALLOWED_TOOLS.has(t), t).toBe(false);
    }
  });
});

describe("HARNESS_TOOLS (single definition, presets re-export)", () => {
  it("is exactly Dart's harnessTools", () => {
    expect(new Set(HARNESS_TOOLS)).toEqual(
      new Set([
        "dispatch_agent",
        "report",
        "update_goal",
        "get_goal",
        "create_goal",
        "memory_save",
      ]),
    );
  });

  it("keeps report in both the allowlist and the harness set (as in Dart)", () => {
    expect(PLAN_ALLOWED_TOOLS.has("report")).toBe(true);
    expect(HARNESS_TOOLS.has("report")).toBe(true);
  });
});

describe("PLAN_HARD_DENIED_PREFIXES", () => {
  it("is the identity-mutating / third-party tool classes", () => {
    expect(PLAN_HARD_DENIED_PREFIXES).toEqual(["device_", "plugin_", "mcp__"]);
  });
});
