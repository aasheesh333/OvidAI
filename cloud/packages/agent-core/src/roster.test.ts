import { describe, expect, it, vi } from "vitest";

import type { ApprovalGate } from "./ports.js";
import { createMemoryStateStore } from "./ports.js";
import { HARNESS_TOOLS, PLAN_ALLOWED_TOOLS } from "./planMode.js";
import { BUILT_IN_PRESETS, presetById, type AgentPreset } from "./presets.js";
import {
  CHILD_DENIED_TOOLS,
  computeToolRoster,
  createExitPlanModeTool,
  isToolPermitted,
  modePolicy,
  type RosterContext,
} from "./roster.js";
import type { ToolContext, ToolSpec } from "./types.js";

// ── fixtures ────────────────────────────────────────────────────────────────

function spec(name: string): ToolSpec {
  return { name, description: name, parameters: { type: "object" } };
}

function ctx(overrides: Partial<RosterContext> = {}): RosterContext {
  return {
    mode: "auto",
    planMode: false,
    isSubagent: false,
    memoryEnabled: true,
    githubConnected: true,
    preset: null,
    activeSkillScopes: [],
    ...overrides,
  };
}

function preset(p: Partial<AgentPreset>): AgentPreset {
  return {
    id: "test",
    label: "Test",
    description: "",
    allowedTools: [],
    deniedTools: [],
    persona: "",
    model: null,
    modelProviderId: null,
    temperature: null,
    ...p,
  };
}

function toolCtx(): ToolContext {
  return {
    sessionId: "s1",
    runId: "r1",
    userId: "u1",
    mode: "auto",
    planMode: true,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "call-1",
    signal: new AbortController().signal,
  };
}

// Every tool name any test here needs, deduped.
const FIXTURE_NAMES: string[] = [
  ...PLAN_ALLOWED_TOOLS,
  ...HARNESS_TOOLS,
  // P2's read-only spellings (ruling R1)
  "read_file",
  "glob_files",
  "grep_files",
  // mutating core tools the plan gate must refuse
  "file_write",
  "fs_edit",
  "multi_edit",
  "commit",
  "run_code",
  "repo_sync",
  "repo_tree",
  "git_push",
  "job_start",
  "job_kill",
  "preview",
  "generate_image",
  "render_html",
  "browser_click",
  "browser_navigate",
  // device / plugin / MCP classes
  "device_tap",
  "device_read",
  "plugin__x__y",
  "mcp__s__t",
  "mcp__srv__ping",
  "mcp__other__x",
  // subagent management + spawn class
  "send_message",
  "list_agents",
  "interrupt_agent",
  "workflow",
  "ralph",
  "request_permission",
  "request_working_folder",
  // scheduler surface (persistent autonomy — must never reach a child)
  "schedule_create",
  "schedule_update",
  "schedule_delete",
  "schedule_list",
  // credential / egress surface (default-deny for children)
  "fetch_url",
  "web_search",
  "repo_sync",
  "git_push",
  "session_search",
  "session_read",
  // memory (harness + plain)
  "memory_save",
  "memory_search",
  "memory_read",
].filter((v, i, a) => a.indexOf(v) === i);

const AVAILABLE: ToolSpec[] = FIXTURE_NAMES.map(spec);

function rosterNames(c: RosterContext, available: readonly ToolSpec[] = AVAILABLE): Set<string> {
  return new Set(computeToolRoster(c, available).map((t) => t.name));
}

// ── plan-mode projection (plan_mode_allowlist_test.dart + G4) ───────────────

describe("computeToolRoster — plan-mode default-deny projection", () => {
  const plan = ctx({ planMode: true });

  it("withholds every mutating tool while planning", () => {
    const names = rosterNames(plan);
    for (const t of [
      "file_write",
      "fs_edit",
      "commit",
      "run_code",
      "repo_sync",
      "plugin__x__y",
      "mcp__s__t",
      "multi_edit",
      "git_push",
      "job_start",
      "preview",
      "generate_image",
      "browser_click",
      "browser_navigate",
      // the spawner is a deliberate escape hatch OUT of plan mode (C1/Dart
      // G4: a child session starts planMode:false and would get the full
      // mutating roster — the union was the drift Dart's test rejects)
      "dispatch_agent",
    ]) {
      expect(names.has(t), `${t} must not be offered while planning`).toBe(false);
    }
  });

  it("offers every PLAN_ALLOWED_TOOLS member while planning", () => {
    const names = rosterNames(plan);
    for (const t of PLAN_ALLOWED_TOOLS) {
      expect(names.has(t), `${t} is on the plan allowlist and must be offered`).toBe(true);
    }
  });

  it("planning is allowlist-ONLY: harness members that are not allowlist members drop (C1)", () => {
    const names = rosterNames(plan);
    // report and get_goal stay — they are allowlist members.
    expect(names.has("report")).toBe(true);
    expect(names.has("get_goal")).toBe(true);
    // The rest of the harness set is withheld while planning (accepted
    // consequence of the C1 ruling; Dart parity).
    expect(names.has("dispatch_agent")).toBe(false);
    expect(names.has("memory_save")).toBe(false);
    expect(names.has("update_goal")).toBe(false);
    expect(names.has("create_goal")).toBe(false);
    // The harness set still survives the OTHER gates it is mandated for:
    // the !memoryEnabled drop and the preset allowlist intersection.
    expect(isToolPermitted("memory_save", ctx({ memoryEnabled: false }))).toBe(true);
    expect(
      isToolPermitted("memory_save", ctx({ preset: preset({ allowedTools: ["file_read"] }) })),
    ).toBe(true);
  });

  it("admits P2's read-only spellings alongside their P3 counterparts (R1)", () => {
    const names = rosterNames(plan);
    expect(names.has("read_file")).toBe(true);
    expect(names.has("glob_files")).toBe(true);
    expect(names.has("grep_files")).toBe(true);
  });
});

// ── gate/roster agreement (plan_mode_jail_test.dart parity) ─────────────────

describe("isToolPermitted agrees with the roster (gate/roster can never disagree)", () => {
  for (const planMode of [false, true]) {
    it(`planMode=${planMode}: the gate and the roster answer identically for every tool`, () => {
      const c = ctx({ planMode });
      const names = rosterNames(c);
      for (const t of AVAILABLE) {
        expect(
          isToolPermitted(t.name, c),
          `gate(${t.name}) must match roster(${t.name})`,
        ).toBe(names.has(t.name));
      }
    });
  }
});

// ── mode gates (composer_modes_test.dart + D5) ──────────────────────────────

describe("computeToolRoster — mode gates", () => {
  it("drops device_* tools in EVERY mode (D5 — no control mode in cloud)", () => {
    for (const mode of ["safe", "auto", "drive", "studio"] as const) {
      const names = rosterNames(ctx({ mode }));
      expect(names.has("device_tap"), `mode=${mode}`).toBe(false);
      expect(names.has("device_read"), `mode=${mode}`).toBe(false);
    }
  });

  it("memoryEnabled:false drops memory_search but KEEPS memory_save (harness wins)", () => {
    const names = rosterNames(ctx({ memoryEnabled: false }));
    expect(names.has("memory_search")).toBe(false);
    expect(names.has("memory_read")).toBe(false);
    // memory_save is a HARNESS_TOOLS member — the harness exemption applies
    // before the memory drop, in the roster and the gate alike.
    expect(names.has("memory_save")).toBe(true);
    expect(isToolPermitted("memory_save", ctx({ memoryEnabled: false }))).toBe(true);
    expect(isToolPermitted("memory_search", ctx({ memoryEnabled: false }))).toBe(false);
  });

  it("githubConnected:false drops repo_sync/repo_tree", () => {
    const names = rosterNames(ctx({ githubConnected: false }));
    expect(names.has("repo_sync")).toBe(false);
    expect(names.has("repo_tree")).toBe(false);
    // repo_read stays — only the sync/tree pair is GitHub-gated.
    expect(names.has("repo_read")).toBe(true);
  });

  it("keeps repo tools when connected", () => {
    const names = rosterNames(ctx({ githubConnected: true }));
    expect(names.has("repo_sync")).toBe(true);
    expect(names.has("repo_tree")).toBe(true);
  });
});

// ── presets (core_regression_test.dart preset legs) ─────────────────────────

describe("computeToolRoster — preset gate", () => {
  it("an allowlist preset keeps only its tools plus the harness set", () => {
    const names = rosterNames(ctx({ preset: preset({ allowedTools: ["file_read"] }) }));
    expect([...names].sort()).toEqual(
      [...new Set(["file_read", ...HARNESS_TOOLS])].sort(),
    );
  });

  it("a denylist preset subtracts its tools and keeps the rest standard", () => {
    const names = rosterNames(ctx({ preset: preset({ deniedTools: ["run_shell"] }) }));
    expect(names.has("run_shell")).toBe(false);
    expect(names.has("file_write")).toBe(true);
    expect(names.has("file_read")).toBe(true);
  });

  it("a null preset is standard (nothing denied)", () => {
    const names = rosterNames(ctx({ preset: null }));
    expect(names.has("run_shell")).toBe(true);
    expect(names.has("file_write")).toBe(true);
  });
});

// ── subagent projection (claude_code_subagent_parity_test.dart legs) ────────

describe("computeToolRoster — subagent projection", () => {
  it("CHILD_DENIED_TOOLS removes the spawn and user-facing classes", () => {
    expect([...CHILD_DENIED_TOOLS].sort()).toEqual(
      [
        "ask_user_question",
        "exit_plan_mode",
        "request_permission",
        "request_working_folder",
        "dispatch_agent",
        "dispatch_agents",
        "workflow",
        "ralph",
        "schedule_create",
        "schedule_update",
        "schedule_delete",
        "schedule_list",
      ].sort(),
    );
  });

  it("isSubagent drops dispatch_agent but keeps the management tools", () => {
    const names = rosterNames(ctx({ isSubagent: true }));
    expect(names.has("dispatch_agent")).toBe(false);
    // The batch form is the same capability and must be denied too.
    expect(names.has("dispatch_agents")).toBe(false);
    expect(names.has("workflow")).toBe(false);
    expect(names.has("ralph")).toBe(false);
    expect(names.has("ask_user_question")).toBe(false);
    expect(names.has("exit_plan_mode")).toBe(false);
    // a child must still talk to its parent and coordinate with siblings
    expect(names.has("send_message")).toBe(true);
    expect(names.has("list_agents")).toBe(true);
    expect(names.has("interrupt_agent")).toBe(true);
    expect(names.has("report")).toBe(true);
  });

  it("a child can never be offered schedule_* (no self-confirmed autonomy)", () => {
    const names = rosterNames(ctx({ isSubagent: true }));
    for (const name of [
      "schedule_create",
      "schedule_update",
      "schedule_delete",
      "schedule_list",
    ]) {
      expect(names.has(name), `${name} must be denied to a child`).toBe(false);
      expect(isToolPermitted(name, ctx({ isSubagent: true }))).toBe(false);
    }
    // The main agent keeps its scheduler surface.
    expect(rosterNames(ctx()).has("schedule_create")).toBe(true);
  });

  it("default-denies the credential/egress class to a child", () => {
    const names = rosterNames(ctx({ isSubagent: true }));
    for (const name of [
      "browser_navigate",
      "browser_click",
      "fetch_url",
      "web_search",
      "mcp__srv__ping",
      "plugin__x__y",
      "repo_sync",
      "git_push",
      "session_search",
      "session_read",
    ]) {
      expect(names.has(name), `${name} must not reach a child by default`).toBe(false);
    }
    // The benign working set still inherits.
    expect(names.has("file_read")).toBe(true);
    expect(names.has("run_shell")).toBe(true);
    expect(names.has("fs_edit")).toBe(true);
  });
});

// ── skill scoping (activeSkillScopes, ruling R4) ────────────────────────────

describe("computeToolRoster — activeSkillScopes", () => {
  it("scopes the roster through nativeToolsFor (skill itself stays — C2)", () => {
    const names = rosterNames(ctx({ activeSkillScopes: ["Edit", "Glob"] }));
    // A plain intersect with NO harness exemption — but the skill tool is
    // exempt so the model can load another skill, which REPLACES the scope
    // (cloud's scopes persist in session state; without this, a scoped
    // skill is an unescapable dead-end).
    expect([...names].sort()).toEqual(["fs_edit", "fs_glob", "skill"]);
  });

  it("the skill-tool exemption holds under every scope shape", () => {
    for (const scopes of [["Edit"], ["mcp__srv"], ["*"], ["Bash(git push *)"]] as const) {
      expect(isToolPermitted("skill", ctx({ activeSkillScopes: [...scopes] }))).toBe(true);
    }
  });

  it("a Bash specifier grant keeps the whole shell/job family", () => {
    const names = rosterNames(ctx({ activeSkillScopes: ["Bash(git push *)"] }));
    expect([...names].sort()).toEqual([
      "job_kill",
      "job_list",
      "job_output",
      "job_start",
      "run_shell",
      "skill", // C2 exemption: the scope-replacing tool survives
    ]);
  });

  it("an MCP server grant keeps that server's tools only", () => {
    const names = rosterNames(ctx({ activeSkillScopes: ["mcp__srv"] }));
    expect(names.has("mcp__srv__ping")).toBe(true);
    expect(names.has("mcp__other__x")).toBe(false);
    expect(names.has("run_shell")).toBe(false);
  });

  it("a bare * inherits everything", () => {
    const names = rosterNames(ctx({ activeSkillScopes: ["*"] }));
    expect(names.has("run_shell")).toBe(true);
    expect(names.has("file_write")).toBe(true);
  });

  it("empty scopes inherit everything", () => {
    const names = rosterNames(ctx({ activeSkillScopes: [] }));
    expect(names.has("run_shell")).toBe(true);
  });
});

// ── ordering (byte-stable for the cache prefix) ─────────────────────────────

describe("computeToolRoster — canonical ordering", () => {
  it("output is name-sorted (canonicalTools)", () => {
    const roster = computeToolRoster(ctx(), AVAILABLE);
    const names = roster.map((t) => t.name);
    expect(names).toEqual([...names].sort());
    // and the roster carries the full spec objects, not just names
    expect(roster[0]).toEqual(AVAILABLE.find((t) => t.name === names[0]));
  });
});

// ── modePolicy ──────────────────────────────────────────────────────────────

describe("modePolicy", () => {
  it("safe: asks before every action, confined, never mutates unattended", () => {
    expect(modePolicy("safe", false)).toEqual({
      canMutate: false,
      confineToWorkspace: true,
      approvalForOutside: true,
      askBeforeActions: true,
    });
  });

  it("auto and studio: mutate, workspace-confined, outside prompts", () => {
    for (const mode of ["auto", "studio"] as const) {
      expect(modePolicy(mode, false)).toEqual({
        canMutate: true,
        confineToWorkspace: true,
        approvalForOutside: true,
        askBeforeActions: false,
      });
    }
  });

  it("drive (not planning): mutate anywhere, no approval for outside", () => {
    expect(modePolicy("drive", false)).toEqual({
      canMutate: true,
      confineToWorkspace: false,
      approvalForOutside: false,
      askBeforeActions: false,
    });
  });

  it("planMode forces safe-like mutation denial regardless of mode", () => {
    for (const mode of ["safe", "auto", "drive", "studio"] as const) {
      expect(modePolicy(mode, true).canMutate, `mode=${mode}`).toBe(false);
    }
    // Full Access does NOT widen plan mode.
    expect(modePolicy("drive", true)).toEqual({
      canMutate: false,
      confineToWorkspace: true,
      approvalForOutside: true,
      askBeforeActions: false,
    });
  });
});

// ── presets module ──────────────────────────────────────────────────────────

describe("BUILT_IN_PRESETS / presetById", () => {
  it("ports the five non-device Dart presets", () => {
    expect(BUILT_IN_PRESETS.map((p) => p.id)).toEqual([
      "standard",
      "minimal",
      "studio",
      "code",
      "plan",
    ]);
  });

  it("standard denies nothing", () => {
    const standard = presetById("standard");
    expect(standard).not.toBeNull();
    expect(standard!.allowedTools).toEqual([]);
    expect(standard!.deniedTools).toEqual([]);
    expect(standard!.persona).toBe("");
  });

  it("minimal is a denylist preset (browser + images + fan-out)", () => {
    const minimal = presetById("minimal")!;
    expect(minimal.allowedTools).toEqual([]);
    expect(minimal.deniedTools).toContain("browser_navigate");
    expect(minimal.deniedTools).toContain("generate_image");
    expect(minimal.deniedTools).toContain("workflow");
    expect(minimal.persona).toContain("lean agent");
  });

  it("code denies the browser and image tools but not workflow", () => {
    const code = presetById("code")!;
    expect(code.deniedTools).toContain("browser_navigate");
    expect(code.deniedTools).toContain("generate_image");
    expect(code.deniedTools).not.toContain("workflow");
  });

  it("plan preset carries the plan persona and no roster narrowing of its own", () => {
    const plan = presetById("plan")!;
    expect(plan.allowedTools).toEqual([]);
    expect(plan.deniedTools).toEqual([]);
    expect(plan.persona).toContain("plan agent");
    // optional cheap-model pin: unset on the built-in (the session may pin)
    expect(plan.model).toBeNull();
  });

  it("presetById returns null for null and unknown ids (null = standard)", () => {
    expect(presetById(null)).toBeNull();
    expect(presetById("nope")).toBeNull();
  });

  it("BUILT_IN_PRESETS is frozen at every level (objects + nested tool lists)", () => {
    // The readonly types are compile-time only; Object.freeze makes the
    // immutability real at runtime — a stray mutation of a shared built-in
    // preset would leak into every session using it.
    expect(Object.isFrozen(BUILT_IN_PRESETS)).toBe(true);
    for (const p of BUILT_IN_PRESETS) {
      expect(Object.isFrozen(p), p.id).toBe(true);
      expect(Object.isFrozen(p.allowedTools), `${p.id}.allowedTools`).toBe(true);
      expect(Object.isFrozen(p.deniedTools), `${p.id}.deniedTools`).toBe(true);
    }
  });

  it("a preset denylist still applies to the skill tool (only the plan projection and skill-scope intersect exempt it)", () => {
    // The C2 exemption is for activeSkillScopes ONLY: a preset that denies
    // `skill` really removes it.
    expect(
      isToolPermitted("skill", ctx({ preset: preset({ deniedTools: ["skill"] }) })),
    ).toBe(false);
    // …and the built-in presets keep it (no built-in denies it).
    expect(isToolPermitted("skill", ctx({ preset: presetById("minimal") }))).toBe(true);
  });
});

// ── exit_plan_mode tool ─────────────────────────────────────────────────────

describe("createExitPlanModeTool", () => {
  it("spec is the exit_plan_mode contract", () => {
    const tool = createExitPlanModeTool({
      state: createMemoryStateStore(),
      approvals: { approve: async () => "allow" },
    });
    expect(tool.spec.name).toBe("exit_plan_mode");
    expect(tool.spec.parameters).toMatchObject({ required: ["plan"] });
  });

  it("approval round-trip: allow clears planMode via state.patch and releases the plan-owned mode", async () => {
    const state = createMemoryStateStore();
    await state.patch("s1", { planMode: true, planPreMode: "auto", mode: "safe", pendingPlanMode: null });
    const approve = vi.fn<ApprovalGate["approve"]>(async () => "allow");
    const tool = createExitPlanModeTool({ state, approvals: { approve } });

    const res = await tool.execute({ plan: "Do the thing" }, toolCtx());

    expect(res.isError).toBeFalsy();
    expect(res.content).toContain("approved");
    // a kind:"plan" round-trip happened before the patch
    expect(approve).toHaveBeenCalledTimes(1);
    const [gateCtx, req] = approve.mock.calls[0];
    expect(req.kind).toBe("plan");
    expect(req.tool).toBe("exit_plan_mode");
    expect(gateCtx.sessionId).toBe("s1");
    // the gate opened NOW, not at the next turn boundary
    const s = await state.get("s1");
    expect(s.planMode).toBe(false);
    expect(s.pendingPlanMode).toBeNull();
    expect(s.mode).toBe("auto"); // _releasePlanOwnedMode: pre-mode restored
    expect(s.planPreMode).toBeNull();
  });

  it("deny leaves plan mode on and the result starts with DENIED", async () => {
    const state = createMemoryStateStore();
    await state.patch("s1", { planMode: true, planPreMode: "auto", mode: "safe" });
    const tool = createExitPlanModeTool({
      state,
      approvals: { approve: async () => "deny" },
    });

    const res = await tool.execute({ plan: "Do the thing" }, toolCtx());

    expect(res.content.startsWith("DENIED")).toBe(true);
    const s = await state.get("s1");
    expect(s.planMode).toBe(true);
    expect(s.mode).toBe("safe");
  });

  it("deny nulls a plan-off queued mid-review (it must not survive the deny)", async () => {
    // Dart parity (`_applyPlanModeNow(session, true)`): the user answered a
    // question about THIS tool result, so a plan-off transition queued while
    // the review card was open is discarded — the session keeps planning.
    const state = createMemoryStateStore();
    await state.patch("s1", {
      planMode: true,
      planPreMode: "auto",
      mode: "safe",
      pendingPlanMode: false,
    });
    const tool = createExitPlanModeTool({
      state,
      approvals: { approve: async () => "deny" },
    });

    const res = await tool.execute({ plan: "Do the thing" }, toolCtx());

    expect(res.content.startsWith("DENIED")).toBe(true);
    const s = await state.get("s1");
    expect(s.planMode).toBe(true);
    expect(s.pendingPlanMode).toBeNull();
  });

  it("releases to auto when no pre-mode was recorded (never leaves the session locked)", async () => {
    const state = createMemoryStateStore();
    await state.patch("s1", { planMode: true, planPreMode: null, mode: "safe" });
    const tool = createExitPlanModeTool({
      state,
      approvals: { approve: async () => "allow" },
    });
    await tool.execute({ plan: "p" }, toolCtx());
    const s = await state.get("s1");
    expect(s.planMode).toBe(false);
    expect(s.mode).toBe("auto");
  });
});
