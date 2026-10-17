// P3 Task 17 — slash-command grammar + server-side built-ins
// (Dart lib/core/commands.dart CommandService.parse + the composer skill path,
// test/slash_command_args_test.dart substitution contract).
//
// Unknown commands return null: the prompt goes to the model verbatim (Dart
// parity — unknown commands are NOT errors).

import { describe, expect, it } from "vitest";

import {
  commandArgumentTrailer,
  commandPrePass,
  createCommandRunner,
  parseSlashCommand,
  substituteCommandArguments,
  type CommandDeps,
} from "./commands.js";
import {
  createMemoryStateStore,
  type SkillCatalog,
} from "./ports.js";
import { createSkillActivation, createSkillTool } from "./tools/skills.js";
import type { SessionMode, ToolContext } from "./types.js";

function fakeCatalog(
  skills: Array<{
    name: string;
    description?: string;
    whenToUse?: string;
    content: string;
    allowedTools?: string[];
    userInvocable?: boolean;
    modelInvocable?: boolean;
  }>,
): SkillCatalog {
  return {
    async list() {
      return skills.map((s) => ({
        name: s.name,
        description: s.description ?? "",
        whenToUse: s.whenToUse ?? "",
        userInvocable: s.userInvocable ?? true,
        modelInvocable: s.modelInvocable ?? true,
      }));
    },
    async load(name) {
      const s = skills.find((x) => x.name.toLowerCase() === name.toLowerCase());
      if (s === undefined) return null;
      return {
        name: s.name,
        description: s.description ?? "",
        whenToUse: s.whenToUse ?? "",
        content: s.content,
        path: `.dsh/skills/${s.name}/SKILL.md`,
        allowedTools: s.allowedTools ?? [],
      };
    },
  };
}

function ctx(sessionId = "s1"): ToolContext {
  return {
    sessionId,
    runId: "r1",
    userId: "u1",
    mode: "auto",
    planMode: false,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "k1",
    signal: new AbortController().signal,
  };
}

function setup(
  opts: {
    skills?: Parameters<typeof fakeCatalog>[0];
    compact?: (sessionId: string) => Promise<string>;
    presets?: CommandDeps["presets"];
  } = {},
) {
  const state = createMemoryStateStore();
  const compactCalls: string[] = [];
  const setModeCalls: Array<{ sessionId: string; mode: SessionMode }> = [];
  const deps: CommandDeps = {
    state,
    skills: fakeCatalog(opts.skills ?? []),
    presets:
      opts.presets ??
      ((id) =>
        id === "plan"
          ? {
              id: "plan",
              label: "Plan",
              description: "",
              allowedTools: [],
              deniedTools: [],
              persona: "",
              model: null,
              modelProviderId: null,
              temperature: null,
            }
          : null),
    async compact(sessionId) {
      compactCalls.push(sessionId);
      return opts.compact ? opts.compact(sessionId) : "Compacted.";
    },
    async setMode(sessionId, mode) {
      setModeCalls.push({ sessionId, mode });
      await state.patch(sessionId, { mode });
      return `Permission → ${mode}`;
    },
  };
  return {
    deps,
    state,
    compactCalls,
    setModeCalls,
    run: createCommandRunner(deps),
  };
}

describe("parseSlashCommand", () => {
  it("parses a command name and its raw args", () => {
    expect(parseSlashCommand("/plan on")).toEqual({ name: "plan", args: "on" });
  });

  it("keeps quoted args verbatim for the handler", () => {
    expect(parseSlashCommand('/skill my-skill "two words"')).toEqual({
      name: "skill",
      args: 'my-skill "two words"',
    });
  });

  it("returns null for bare text (not a command)", () => {
    expect(parseSlashCommand("hello /plan")).toBeNull();
    expect(parseSlashCommand("")).toBeNull();
  });

  it("returns null when the slash is not followed by the command grammar", () => {
    expect(parseSlashCommand("/ Upper")).toBeNull();
    expect(parseSlashCommand("/")).toBeNull();
  });

  it("accepts the [a-z0-9_-]+ grammar and trims the remainder", () => {
    expect(parseSlashCommand("/model   claude-x  ")).toEqual({
      name: "model",
      args: "claude-x",
    });
  });
});

describe("substituteCommandArguments (slash_command_args_test.dart parity)", () => {
  it("replaces $ARGUMENTS with the full argument string", () => {
    expect(
      substituteCommandArguments(
        "Summarize $ARGUMENTS please",
        "the release notes",
      ),
    ).toBe("Summarize the release notes please");
  });

  it("replaces $@ with the full argument string", () => {
    expect(substituteCommandArguments("Run $@ now", "a b c")).toBe(
      "Run a b c now",
    );
  });

  it("replaces positional $1/$2 from whitespace-split args", () => {
    expect(substituteCommandArguments("Fix issue $1 in $2", "auth login")).toBe(
      "Fix issue auth in login",
    );
  });

  it("supports multi-digit positionals ($10)", () => {
    expect(substituteCommandArguments("$10", "a b c d e f g h i j")).toBe("j");
  });

  it("leaves out-of-range positionals as-is", () => {
    expect(substituteCommandArguments("A $3 B", "x y")).toBe("A $3 B");
    expect(substituteCommandArguments("A $10 B", "x y")).toBe("A $10 B");
  });

  it("unescapes \\$ without substituting", () => {
    expect(substituteCommandArguments("cost \\$5 and $1", "x")).toBe(
      "cost $5 and x",
    );
    expect(substituteCommandArguments("\\$ARGUMENTS", "ignored")).toBe(
      "$ARGUMENTS",
    );
  });

  it("leaves the body unchanged when it has no placeholders", () => {
    expect(substituteCommandArguments("plain instruction", "args")).toBe(
      "plain instruction",
    );
  });

  it("substitutes multiple occurrences", () => {
    expect(
      substituteCommandArguments("$1 then $1 then $ARGUMENTS", "one two"),
    ).toBe("one then one then one two");
  });
});

describe("commandArgumentTrailer", () => {
  it("appends the legacy trailer when no placeholders exist", () => {
    expect(commandArgumentTrailer("plain instruction", "a b", "Arguments")).toBe(
      "\n\nArguments: a b",
    );
    expect(
      commandArgumentTrailer("plain instruction", "do it", "User instruction"),
    ).toBe("\n\nUser instruction: do it");
  });

  it("is empty when the body declares placeholders", () => {
    expect(commandArgumentTrailer("Fix $1", "a b", "Arguments")).toBe("");
    expect(commandArgumentTrailer("Fix $ARGUMENTS", "a b", "Arguments")).toBe(
      "",
    );
  });

  it("is empty when there are no arguments", () => {
    expect(commandArgumentTrailer("plain instruction", "", "Arguments")).toBe(
      "",
    );
  });
});

describe("createCommandRunner", () => {
  it("/plan on persists pendingPlanMode and returns feedback only (no model call)", async () => {
    const { run, state } = setup();
    const res = await run("s1", "/plan on");
    expect(res).toEqual({ feedback: "Plan mode on.", clearInput: true });
    expect((await state.get("s1")).pendingPlanMode).toBe(true);
  });

  it("/plan off clears the pending plan transition", async () => {
    const { run, state } = setup();
    await state.patch("s1", { pendingPlanMode: true });
    const res = await run("s1", "/plan off");
    expect(res).toEqual({ feedback: "Plan mode off.", clearInput: true });
    expect((await state.get("s1")).pendingPlanMode).toBe(false);
  });

  it("/plan <message> rewrites the prompt (Dart /plan message parity)", async () => {
    const { run, state } = setup();
    const res = await run("s1", "/plan research the repo");
    expect(res?.prompt).toBe("research the repo");
    expect((await state.get("s1")).pendingPlanMode).toBe(true);
  });

  it("/permission drive sets mode through the store (R4 persistence)", async () => {
    const { run, state, setModeCalls } = setup();
    const res = await run("s1", "/permission drive");
    expect(res?.feedback).toContain("drive");
    expect(setModeCalls).toEqual([{ sessionId: "s1", mode: "drive" }]);
    expect((await state.get("s1")).mode).toBe("drive");
  });

  it("/permission accepts the Dart mode aliases", async () => {
    const { run, setModeCalls } = setup();
    await run("s1", "/permission read-only");
    await run("s1", "/permission full_access");
    expect(setModeCalls.map((c) => c.mode)).toEqual(["safe", "drive"]);
  });

  it("/permission with an unknown mode returns options, not a null miss", async () => {
    const { run } = setup();
    const res = await run("s1", "/permission nope");
    expect(res?.feedback).toContain("Unknown permission");
    expect(res?.feedback).toContain("safe");
  });

  it("/model claude-x records the session model pin", async () => {
    const { run, state } = setup();
    const res = await run("s1", "/model claude-x");
    expect(res?.feedback).toContain("claude-x");
    expect((await state.get("s1")).modelPin).toBe("claude-x");
  });

  it("/compact calls the compactor exactly once and returns its status", async () => {
    const { run, compactCalls } = setup({ compact: async () => "Compacted 12 rows." });
    const res = await run("s1", "/compact focus on auth");
    expect(compactCalls).toEqual(["s1"]);
    expect(res).toEqual({ feedback: "Compacted 12 rows.", clearInput: true });
  });

  it("/todo renders the checklist marks from state.todos", async () => {
    const { run, state } = setup();
    await state.patch("s1", {
      todos: [
        { content: "done", status: "completed" },
        { content: "doing", status: "in_progress" },
        { content: "later", status: "pending" },
      ],
    });
    const res = await run("s1", "/todo");
    expect(res?.feedback).toBe("- [x] done\n- [~] doing\n- [ ] later");
  });

  it("/todo says so when the list is empty", async () => {
    const { run } = setup();
    expect((await run("s1", "/todo"))?.feedback).toBe("No todos.");
  });

  it("unknown /name → null (prompt goes to the model verbatim)", async () => {
    const { run } = setup();
    expect(await run("s1", "/unknowncmd x")).toBeNull();
  });

  it("falls through to parseSkillInvocation for names outside the command grammar", async () => {
    // I1: Dart's composer tries CommandService.parse first, then
    // parseSkillInvocation, which accepts ANY non-whitespace token.
    const { run } = setup({
      skills: [
        { name: "Tip", content: "TIP BODY", userInvocable: true },
        { name: "my.skill", content: "DOTTED BODY", userInvocable: true },
      ],
    });
    expect((await run("s1", "/Tip now"))?.prompt).toBe(
      "<skill_content>\nTIP BODY\n</skill_content>\n\nUser instruction: now",
    );
    expect((await run("s1", "/my.skill two words"))?.prompt).toBe(
      "<skill_content>\nDOTTED BODY\n</skill_content>\n\nUser instruction: two words",
    );
  });

  it("an unknown non-grammar name still → null", async () => {
    const { run } = setup();
    expect(await run("s1", "/Nope x")).toBeNull();
    expect(await run("s1", "/my.missing")).toBeNull();
  });

  it("non-command input → null", async () => {
    const { run } = setup();
    expect(await run("s1", "just text")).toBeNull();
  });

  it("/skill-name rewrites user-invocable skill content with substituted args", async () => {
    const { run } = setup({
      skills: [
        {
          name: "release",
          content: "Cut $1 with $ARGUMENTS",
          userInvocable: true,
        },
      ],
    });
    const res = await run("s1", "/release v2 careful");
    // The body declares placeholders → no legacy trailer.
    expect(res?.prompt).toBe(
      "<skill_content>\nCut v2 with v2 careful\n</skill_content>",
    );
  });

  it("/skill-name appends the legacy user-instruction trailer when the body has no placeholders", async () => {
    const { run } = setup({
      skills: [
        { name: "release", content: "Cut a release.", userInvocable: true },
      ],
    });
    const res = await run("s1", "/release v2 careful");
    expect(res?.prompt).toBe(
      "<skill_content>\nCut a release.\n</skill_content>\n\nUser instruction: v2 careful",
    );
  });

  it("a non-user-invocable skill is NOT a slash command (falls through to null)", async () => {
    const { run } = setup({
      skills: [
        { name: "manual", content: "MANUAL", userInvocable: false },
      ],
    });
    expect(await run("s1", "/manual now")).toBeNull();
  });

  it("built-ins shadow a same-named skill", async () => {
    const { run, state } = setup({
      skills: [{ name: "plan", content: "SHOULD NOT RUN" }],
    });
    const res = await run("s1", "/plan on");
    expect(res?.prompt).toBeUndefined();
    expect((await state.get("s1")).pendingPlanMode).toBe(true);
  });
});

describe("skill activation persistence (R4)", () => {
  it("persists the expanded activeSkillScopes through the default runner hook", async () => {
    const state = createMemoryStateStore();
    const catalog = fakeCatalog([
      {
        name: "locked",
        content: "Only read things.",
        allowedTools: ["Read", "Glob"],
      },
    ]);
    const tool = createSkillTool({
      catalog,
      onActivate: createSkillActivation(state),
    });
    await tool.execute({ name: "locked" }, ctx("s1"));
    expect((await state.get("s1")).activeSkillScopes).toEqual([
      "file_read",
      "read_image",
      "read_attachment",
      "fs_glob",
    ]);
  });
});

describe("commandPrePass (engine hook point)", () => {
  it("a feedback-only command finishes the run without a prompt", async () => {
    const { run } = setup();
    expect(await commandPrePass(run, "s1", "/plan on")).toEqual({
      kind: "finish",
      feedback: "Plan mode on.",
    });
  });

  it("a skill rewrite replaces the prompt", async () => {
    const { run } = setup({
      skills: [{ name: "release", content: "Cut a release." }],
    });
    const pre = await commandPrePass(run, "s1", "/release now");
    expect(pre.kind).toBe("rewrite");
    if (pre.kind === "rewrite") expect(pre.prompt).toContain("Cut a release.");
  });

  it("non-commands pass through untouched", async () => {
    const { run } = setup();
    expect(await commandPrePass(run, "s1", "hello")).toEqual({ kind: "none" });
  });
});
