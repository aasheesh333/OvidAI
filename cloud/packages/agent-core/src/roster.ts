// Tool-roster computation + mode/plan policy (port of `AgentService._tools`
// roster projection, `_childDeniedTools`, and the mode gates — agent_service.
// dart ~7350–7600, ~11320).
//
// SINGLE SOURCE OF TRUTH: `computeToolRoster` (what the model is OFFERED) and
// `isToolPermitted` (what the Task 15 dispatch gate lets THROUGH) are the
// same filter — the roster is `available.filter(isToolPermitted)`, so the
// two enforcement points can never disagree. A tool the gate would refuse is
// never advertised, so the model is not billed for (nor tempted by) it.
//
// Pipeline (order pinned by the plan brief; all steps are conjunctive
// filters, so the set result is order-independent — the ordering below is
// the documented reading order):
//   1. drop `device_*` ALWAYS (D5 — Control mode does not exist in cloud);
//   2. drop `memory_*` when !memoryEnabled — EXCEPT HARNESS_TOOLS members
//      (the harness exemption applies before the memory drop: memory_save is
//      harness, so `memoryEnabled:false` drops memory_search but KEEPS
//      memory_save);
//   3. drop repo_sync/repo_tree when !githubConnected;
//   4. planMode → keep only PLAN_ALLOWED_TOOLS ∪ the P2 read-only aliases
//      (R1) — allowlist-ONLY, no harness union (C1 ruling: Dart's shipped
//      gate and roster both refuse dispatch_agent while planning; the union
//      is the drift Dart's G4 test rejects) — and never a
//      PLAN_HARD_DENIED_PREFIXES match;
//   5. isSubagent → drop CHILD_DENIED_TOOLS, the schedule_/device_ prefix
//      classes and the default-deny credential/egress set (layer 2 of 3: a
//      child never even SEES the spawn/user-facing/scheduler tools;
//      management tools stay so it can talk to its parent and coordinate
//      with siblings). Credential/egress tools can be re-admitted only by an
//      explicit dispatch allowlist;
//   6. preset: allowedTools non-empty → intersection (harness always kept);
//      else deniedTools → subtraction;
//   7. activeSkillScopes non-empty → intersect through nativeToolsFor —
//      a PLAIN intersect with no harness exemption (C2 ruling: that IS the
//      allowed-tools contract), EXCEPT the `skill` tool itself (Dart
//      parity: "always allowed so the model can load another skill (which
//      replaces the scope)" — in cloud the scopes persist in session state,
//      so without this a scoped skill would be an unescapable dead-end);
//   8. canonicalTools sort (byte-stable order for the cache prefix, Task 3).

import { nativeToolsFor } from "./claudeCodeTools.js";
import { HARNESS_TOOLS, planRosterAdmits } from "./planMode.js";
import type { ApprovalGate, ApprovalRequest, SessionStateStore } from "./ports.js";
import { canonicalTools } from "./promptCache.js";
import type { AgentPreset } from "./presets.js";
import type { SessionMode, Tool, ToolContext, ToolSpec } from "./types.js";

export interface RosterContext {
  mode: SessionMode;
  planMode: boolean;
  isSubagent: boolean;
  memoryEnabled: boolean;
  githubConnected: boolean;
  preset: AgentPreset | null;
  activeSkillScopes: readonly string[];
}

/// Subagent tool policy (Dart `_childDeniedTools`, verbatim): the spawn
/// class (a subagent can NEVER spawn a subagent) plus the user-facing tools
/// (no user is watching a child's session — it must not hijack the parent's
/// composer with questions or plan reviews). The management tools —
/// send_message, list_agents, interrupt_agent, report — deliberately stay.
///
/// SECURITY (SI spec §9 hardening): scheduling is also denied. A child must
/// never be able to mint a persistent autonomous run (schedule_create with
/// `confirmed:true`) on the user's behalf; scheduling needs a real user
/// confirmation in an attended main-agent session. `CHILD_DENIED_PREFIXES`
/// below catches future `schedule_*` tools too.
export const CHILD_DENIED_TOOLS: ReadonlySet<string> = new Set([
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
]);

/// Prefix classes a child may never use, even when the dispatch policy
/// explicitly allows them. `device_*` is denied for every session (D5);
/// `schedule_*` is the persistent-autonomy class (see above).
export const CHILD_DENIED_PREFIXES: readonly string[] = ["schedule_", "device_"];

/// Credential/egress classes that a child gets ONLY when the dispatch policy
/// name-allowlists them (an omitted `tools` list, or a bare `*`, is not an
/// allowlist). A child inherits the parent's credentials and network path, so
/// browser control, MCP/plugin servers (stored credentials), web egress and
/// repository sync are default-deny.
export const CHILD_SENSITIVE_PREFIXES: readonly string[] = [
  "browser_",
  "mcp__",
  "plugin__",
];

/// Exact-name members of the default-deny credential/egress set.
export const CHILD_SENSITIVE_TOOLS: ReadonlySet<string> = new Set([
  "fetch_url",
  "web_search",
  "repo_sync",
  "repo_tree",
  "git_clone",
  "git_push",
  "commit",
  "preview",
  "generate_image",
  "session_search",
  "session_read",
]);

/** Never allowed to a child, whatever the policy says. */
export function isChildHardDeniedTool(name: string): boolean {
  if (CHILD_DENIED_TOOLS.has(name)) return true;
  return CHILD_DENIED_PREFIXES.some((prefix) => name.startsWith(prefix));
}

/** Sensitive (credentials/egress); needs an explicit per-dispatch allow. */
export function isChildSensitiveTool(name: string): boolean {
  if (CHILD_SENSITIVE_TOOLS.has(name)) return true;
  return CHILD_SENSITIVE_PREFIXES.some((prefix) => name.startsWith(prefix));
}

/// The GitHub-sync-gated pair (Dart `_repoToolNames`): without a connection
/// the agent works purely in the local workspace.
const REPO_TOOLS: ReadonlySet<string> = new Set(["repo_sync", "repo_tree"]);

/// Does one skill-scope entry cover [name]? Entries expand through
/// nativeToolsFor; pattern entries (trailing `*`, from MCP server grants and
/// prefix wildcards) match by prefix.
function scopeAdmits(name: string, scopes: readonly string[]): boolean {
  for (const entry of scopes) {
    for (const granted of nativeToolsFor(entry)) {
      if (granted === "*") return true;
      if (granted.endsWith("*")) {
        if (name.startsWith(granted.slice(0, -1))) return true;
      } else if (granted === name) return true;
    }
  }
  return false;
}

/**
 * The gate-side twin of the roster filter — one implementation, two call
 * sites (Task 15's dispatch gate calls this; computeToolRoster inlines it).
 */
export function isToolPermitted(name: string, ctx: RosterContext): boolean {
  // 1. device_* never exist in the cloud roster (D5).
  if (name.startsWith("device_")) return false;
  // 2. Memory toggle OFF → no memory_* tools — except the harness set
  //    (memory_save survives: the harness exemption applies before the drop).
  if (!ctx.memoryEnabled && name.startsWith("memory_") && !HARNESS_TOOLS.has(name)) {
    return false;
  }
  // 3. GitHub sync OFF → no repo_sync/repo_tree.
  if (!ctx.githubConnected && REPO_TOOLS.has(name)) return false;
  // 4. Plan mode: default-deny projection.
  if (ctx.planMode && !planRosterAdmits(name)) return false;
  // 5. A subagent never sees the spawn, user-facing, scheduling or
  //    credential/egress classes. Sensitive tools are default-deny here; a
  //    dispatch can re-admit one only through its explicit `tools` allowlist
  //    (see subagentPolicyAllows in subagents.ts).
  if (ctx.isSubagent && (isChildHardDeniedTool(name) || isChildSensitiveTool(name))) {
    return false;
  }
  // 6. Preset composition (allowlist keeps the harness; denylist subtracts).
  const preset = ctx.preset;
  if (preset) {
    if (preset.allowedTools.length > 0) {
      if (!preset.allowedTools.includes(name) && !HARNESS_TOOLS.has(name)) return false;
    } else if (preset.deniedTools.includes(name)) {
      return false;
    }
  }
  // 7. Active skill scopes narrow the roster to what the skill grants — a
  //    plain intersect (no harness exemption; C2 ruling) — except the skill
  //    tool itself, which stays available so the model can load another
  //    skill and REPLACE the scope (the only path that clears it).
  if (
    ctx.activeSkillScopes.length > 0 &&
    name !== "skill" &&
    !scopeAdmits(name, ctx.activeSkillScopes)
  ) {
    return false;
  }
  return true;
}

/**
 * The model-visible roster: [available] filtered through isToolPermitted,
 * then canonicalized (name-sorted, key-sorted) so the serialised roster is
 * byte-identical turn to turn regardless of plugin/MCP load order (the
 * cache-stable prefix, Task 3).
 *
 * ctx.mode is not itself a roster filter — mode gates approvals (see
 * modePolicy), not visibility; it rides on RosterContext because the same
 * computation feeds ToolContext.mode (ruling R4).
 */
export function computeToolRoster(
  ctx: RosterContext,
  available: readonly ToolSpec[],
): ToolSpec[] {
  return canonicalTools(available.filter((t) => isToolPermitted(t.name, ctx)));
}

/**
 * The access-mode policy the Task 15 dispatch path consults for mutating
 * tools (identity-mutating tools are denied outright where canMutate is
 * false; confineToWorkspace/approvalForOutside decide whether an
 * outside-workspace target is refused or prompted).
 *
 * planMode forces safe-like mutation denial REGARDLESS of mode — Full Access
 * does not widen the plan phase. Destructive-command confirmation applies in
 * ALL modes and is checked before any hook allow (Task 15); it is not a
 * modePolicy field for exactly that reason.
 */
export interface ModePolicy {
  /** false → identity-mutating tools are refused outright (plan; unattended Read-Only). */
  canMutate: boolean;
  confineToWorkspace: boolean;
  approvalForOutside: boolean;
  /**
   * Wave 1a (CH-001): Read-Only's promise — "Asks for permission before every
   * shell, browser, or write action." In an ATTENDED run every shell/code/job
   * call, browser_* call, network fetch and mutating tool raises an approval
   * card before dispatch (allow → it runs). An UNATTENDED Read-Only run (a
   * `safe` schedule) has nobody to ask: mutating tools fall back to the
   * outright canMutate:false denial and reads run.
   */
  askBeforeActions: boolean;
}

export function modePolicy(mode: SessionMode, planMode: boolean): ModePolicy {
  if (planMode) {
    return { canMutate: false, confineToWorkspace: true, approvalForOutside: true, askBeforeActions: false };
  }
  switch (mode) {
    case "safe":
      // Read-Only: every action asks first (attended); reads stay inside the
      // workspace; unattended runs never mutate.
      return { canMutate: false, confineToWorkspace: true, approvalForOutside: true, askBeforeActions: true };
    case "auto":
    case "studio":
      // General / Studio: mutate, workspace-confined, outside targets prompt.
      return { canMutate: true, confineToWorkspace: true, approvalForOutside: true, askBeforeActions: false };
    case "drive":
      // Full Access: mutate anywhere, no confirmation for outside targets.
      return { canMutate: true, confineToWorkspace: false, approvalForOutside: false, askBeforeActions: false };
  }
}

/**
 * The exit_plan_mode tool (Dart `_handleExitPlanMode` + the G2 immediate-
 * apply ruling): finish planning and offer the switch to the build agent.
 *
 * The approval is an explicit user decision tied to THIS tool result — the
 * model is about to start building, so the gate opens NOW via state.patch
 * (never queued at the turn boundary: queueing would lock the approved plan
 * out of the very tools it just earned). An immediate apply also clears any
 * queued transition, so the queue and the live value can never disagree
 * (Dart `_applyPlanModeNow`). Every plan-mode exit releases the plan-owned
 * Read-Only mode (`_releasePlanOwnedMode`): the recorded pre-mode is
 * restored, or `auto` when none was — never a session left locked.
 *
 * Plan reviews WAIT: the attended approval has no 120 s auto-deny (Dart:
 * "question cards and plan reviews keep waiting") — that is the Task 12
 * gate's timeout seam, not this tool's; the timeoutMs below is a floor high
 * enough (1 h) that a waiting plan review is never killed by the per-tool
 * timeout instead.
 */
export function createExitPlanModeTool(deps: {
  state: SessionStateStore;
  approvals: ApprovalGate;
}): Tool {
  return {
    spec: {
      name: "exit_plan_mode",
      description:
        "Finish planning and offer to start building.  Call this once you " +
        "have researched the workspace and written the plan out in your " +
        "own words as a NORMAL MESSAGE.  This does not open a plan card: " +
        "it asks the user a single yes/no question — switch to the build " +
        "agent and start implementing?  Write the plan as numbered steps " +
        "in the message BEFORE calling this; the argument here is only a " +
        "short recap for context.",
      parameters: {
        type: "object",
        properties: {
          plan: {
            type: "string",
            description:
              "Short recap of the plan you already wrote out as a message " +
              "(the user reads the full plan from that message, not from " +
              "this field).",
          },
        },
        required: ["plan"],
      },
    },
    timeoutMs: 60 * 60 * 1000,
    async execute(
      args: Record<string, unknown>,
      ctx: ToolContext,
    ): Promise<{ content: string; isError?: boolean }> {
      const plan = typeof args.plan === "string" ? args.plan.trim() : "";
      // Keep the recap short: the plan belongs in the message, not the card.
      const recap = plan.length <= 240 ? plan : `${plan.slice(0, 240)}…`;
      const req: ApprovalRequest = {
        approvalId: `plan-exit:${ctx.runId}`,
        kind: "plan",
        tool: "exit_plan_mode",
        summary: "Plan complete — switch to the build agent and start implementing?",
        detail:
          recap === ""
            ? "Plan complete. Would you like to switch to the build agent and start implementing?"
            : `Plan complete. Would you like to switch to the build agent and start implementing?\n\n${recap}`,
        allowAlways: false,
        pathTargets: [],
        hostTargets: [],
      };
      const decision = await deps.approvals.approve(ctx, req);
      if (decision !== "allow" && decision !== "always") {
        // Stay in plan mode. Applied immediately (Dart `_applyPlanModeNow(
        // session, true)` parity): the user answered a question about THIS
        // tool result, not about a future turn — and a plan-off transition
        // queued mid-review (the Plan chip toggled while the card was open)
        // must NOT survive the deny and flip plan mode off at the next
        // boundary.
        await deps.state.patch(ctx.sessionId, { planMode: true, pendingPlanMode: null });
        return {
          content:
            "DENIED: the user did not approve — they chose to keep planning. " +
            "Refine the plan and call exit_plan_mode again when it is ready.",
        };
      }
      const s = await deps.state.get(ctx.sessionId);
      const patch: Parameters<SessionStateStore["patch"]>[1] = {
        planMode: false,
        pendingPlanMode: null,
      };
      // Release the plan-owned Read-Only mode (Dart `_releasePlanOwnedMode`).
      const pre = s.planPreMode;
      patch.planPreMode = null;
      if (pre === "safe" || pre === "auto" || pre === "drive" || pre === "studio") {
        patch.mode = pre;
      } else if (s.mode === "safe") {
        patch.mode = "auto";
      }
      await deps.state.patch(ctx.sessionId, patch);
      return { content: "Plan approved ✓ — switch to the build agent and execute the plan." };
    },
  };
}
