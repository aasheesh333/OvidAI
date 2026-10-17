// The `skill` tool (port of agent_service.dart `_handleSkill`,
// AS:23543–23601). Loading a named skill:
//   1. hot-reloads the workspace catalog (the cloud catalog re-scans on every
//      call — see skillsLoader.ts);
//   2. persists the skill's allowed-tools as the session's active scope via
//      `onActivate` (the runner's default writes
//      `state.patch({activeSkillScopes: scopes})`, ruling R4) — an EMPTY list
//      CLEARS the scope, Dart parity;
//   3. returns the skill body, wrapped in `<skill_content>`, with
//      `$ARGUMENTS`/`$1` substitution applied.
//
// The roster narrows from the NEXT turn (computeToolRoster reads the store per
// request), and the `skill` tool itself is exempt from the scope (roster.ts
// step 7) so the model can load another skill to replace it.
//
// CLOUD DEVIATIONS (recorded):
//   • Dart scopes the RUN and resets at every fresh user turn; the cloud
//     persists scopes in SessionAgentState (ruling R4) until another skill
//     load replaces them.
//   • The scope is `nativeToolsFor`-EXPANDED (C2 ruling), not Dart's raw
//     containment.
//   • Supporting-file inlining (`_skillContentWithFiles`) is
//     deleted-with-comment — the landed Skill port has no dirPath/
//     supportingFiles and the tool returns the body verbatim (the loop spills
//     at 6000).
//   • Ambiguous-alias resolution cannot arise in the single-root cloud
//     catalog (bundle-beats-flat + first-wins), so that branch is deleted.

import type { SessionStateStore, SkillCatalog } from "../ports.js";
import { substituteCommandArguments } from "../commands.js";
import type { Tool, ToolContext, ToolResult } from "../types.js";
import { skillAllowedTools } from "../skillsLoader.js";

/** Default tool timeout (Dart `_toolTimeoutFor`: 2 min for everything else). */
const SKILL_TOOL_TIMEOUT_MS = 120_000;

/**
 * The runner's DEFAULT `onActivate` for `createSkillTool`: persist the loaded
 * skill's scope in the session state (ruling R4), which is the single source
 * the roster reads on the NEXT turn.
 *
 * WIRING (T16, per run — the registry has no userId at construction time):
 *
 *   const catalog = createSkillCatalog({ sandbox, userId });   // userId required
 *   const skill = createSkillTool({
 *     catalog,
 *     onActivate: createSkillActivation(state),
 *   });
 *   registry = [...tools, skill];                              // the "skill" tool
 *
 * `scopes` may be `[]` (a skill with no allowed-tools): the patch then CLEARS
 * a previously active scope, Dart parity.
 */
export function createSkillActivation(
  state: SessionStateStore,
): (sessionId: string, scopes: string[]) => Promise<void> {
  return (sessionId, scopes) =>
    state.patch(sessionId, { activeSkillScopes: scopes });
}

export function createSkillTool(deps: {
  catalog: SkillCatalog;
  /**
   * Persist the newly loaded skill's scope. `[]` means "no restriction" and
   * MUST be written (loading an unrestricted skill clears a prior scope).
   * Wire `createSkillActivation(state)` here — see its doc for the exact
   * per-run registration.
   */
  onActivate(sessionId: string, scopes: string[]): Promise<void>;
}): Tool {
  return {
    spec: {
      name: "skill",
      description:
        "Load named workflow instructions when requested or when a skill " +
        "catalog entry matches the task.",
      parameters: {
        type: "object",
        properties: {
          name: {
            type: "string",
            description: "The skill name from the available-skills catalog.",
          },
        },
        required: ["name"],
      },
    },
    timeoutMs: SKILL_TOOL_TIMEOUT_MS,

    async execute(
      args: Record<string, unknown>,
      ctx: ToolContext,
    ): Promise<ToolResult> {
      const rawName = args.name;
      const name = typeof rawName === "string" ? rawName.trim() : "";
      if (name === "") {
        return { content: "skill name is required", isError: true };
      }

      const skill = await deps.catalog.load(name, ctx.sessionId);
      if (skill === null) {
        const summaries = await deps.catalog.list(ctx.sessionId);
        const available = summaries
          .filter((s) => s.modelInvocable)
          .map((s) => s.name);
        return {
          content:
            available.length === 0
              ? `No skill named "${name}". No skills are installed yet.`
              : `No skill named "${name}". Available: ${available.join(", ")}`,
          isError: true,
        };
      }

      // Persist the scope BEFORE returning the content: the next roster is
      // computed from the store. An unrestricted skill patches `[]`.
      await deps.onActivate(ctx.sessionId, skillAllowedTools(skill));

      const rawArgs =
        typeof args.input === "string"
          ? args.input
          : typeof args.arguments === "string"
            ? args.arguments
            : "";
      const content = substituteCommandArguments(skill.content, rawArgs);
      // The loop's dispatch spills oversized results at 6000
      // (toolOutputCapFor("skill")); returning the body verbatim keeps the
      // tool independent of the sandbox port.
      return { content: `<skill_content>\n${content}\n</skill_content>` };
    },
  };
}
