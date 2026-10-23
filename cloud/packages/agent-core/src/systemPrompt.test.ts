import { describe, expect, it } from "vitest";

import type { SessionGoal, SkillSummary, TodoItem } from "./ports.js";
import type { SessionMode } from "./types.js";
import {
  buildSystemPrompt,
  modeSection,
  planBriefing,
  type SystemPromptInput,
} from "./systemPrompt.js";

// ── fixtures ────────────────────────────────────────────────────────────────

function input(overrides: Partial<SystemPromptInput> = {}): SystemPromptInput {
  return {
    mode: "auto",
    planMode: false,
    isSubagent: false,
    persona: "",
    workspaceFolder: "/work/s-1",
    workspaceTreeSummary: "",
    skillsCatalog: [],
    memoryContext: "",
    todos: [],
    goal: null,
    ...overrides,
  };
}

const TODOS: TodoItem[] = [
  { content: "done thing", status: "completed" },
  { content: "live thing", status: "in_progress" },
  { content: "later thing", status: "pending" },
];

const GOAL: SessionGoal = { objective: "ship the thing", notes: "" };

const SKILLS: SkillSummary[] = [
  {
    name: "deploy",
    description: "Deploys the app",
    whenToUse: "release tasks",
    userInvocable: true,
    modelInvocable: true,
  },
  {
    name: "useronly",
    description: "user-invocable only",
    whenToUse: "",
    userInvocable: true,
    modelInvocable: false,
  },
];

/** The first line of the base identity block. */
const IDENTITY_LINE = "You are Ovid's cloud coding & browsing agent";

// ── byte-stability (Review Focus #3) ────────────────────────────────────────

describe("buildSystemPrompt byte-stability", () => {
  it("identical inputs produce byte-identical output (pure function)", () => {
    const i = input({
      planMode: true,
      persona: "P",
      todos: TODOS,
      goal: GOAL,
      skillsCatalog: SKILLS,
      memoryContext: "MEMORY_FACT",
      workspaceTreeSummary: "src/ (3 files)",
    });
    const a = buildSystemPrompt(i);
    const b = buildSystemPrompt(i);
    expect(b.stable).toBe(a.stable);
    expect(b.volatile).toBe(a.volatile);
  });

  it("different todos leave stable byte-identical and change volatile", () => {
    const a = buildSystemPrompt(input({ todos: TODOS.slice(0, 1) }));
    const b = buildSystemPrompt(input({ todos: TODOS }));
    expect(b.stable).toBe(a.stable);
    expect(b.volatile).not.toBe(a.volatile);
  });

  it("a different workspace tree changes only volatile", () => {
    const a = buildSystemPrompt(input({ workspaceTreeSummary: "one" }));
    const b = buildSystemPrompt(input({ workspaceTreeSummary: "two" }));
    expect(b.stable).toBe(a.stable);
    expect(a.volatile).toContain("one");
    expect(b.volatile).toContain("two");
  });

  it("volatile is empty when there is nothing volatile", () => {
    expect(buildSystemPrompt(input()).volatile).toBe("");
  });
});

// ── stable composition ──────────────────────────────────────────────────────

describe("stable composition", () => {
  it("persona renders above the base identity line", () => {
    const r = buildSystemPrompt(input({ persona: "P" }));
    expect(r.stable.indexOf("PERSONA: P")).toBeLessThan(
      r.stable.indexOf(IDENTITY_LINE),
    );
    // and above everything else — the persona preamble rides first
    expect(r.stable.startsWith("PERSONA: P\n")).toBe(true);
  });

  it("base identity carries the workspace folder", () => {
    const r = buildSystemPrompt(input());
    expect(r.stable).toContain("Current workspace: /work/s-1");
    expect(r.stable).toContain(
      "do not clone again to begin working",
    );
  });

  it("workspace folder never leaks into volatile", () => {
    const r = buildSystemPrompt(input({ workspaceTreeSummary: "tree" }));
    expect(r.volatile).not.toContain("/work/s-1");
  });

  it("skills catalog renders model-invocable lines only", () => {
    const r = buildSystemPrompt(input({ skillsCatalog: SKILLS }));
    expect(r.stable).toContain(
      "AVAILABLE SKILLS (call the `skill` tool with a name to load full instructions):",
    );
    expect(r.stable).toContain("- `deploy`: Deploys the app — release tasks");
    // modelInvocable:false rows are not offered to the model
    expect(r.stable).not.toContain("user-invocable only");
    expect(r.volatile).not.toContain("deploy");
  });

  it("skill descriptions are capped at 500 chars with an ellipsis", () => {
    const long = "x".repeat(600);
    const r = buildSystemPrompt(
      input({
        skillsCatalog: [
          {
            name: "big",
            description: long,
            whenToUse: "",
            userInvocable: false,
            modelInvocable: true,
          },
        ],
      }),
    );
    expect(r.stable).toContain(`- \`big\`: ${"x".repeat(500)}…`);
  });

  it("memory context rides in stable (never volatile)", () => {
    const r = buildSystemPrompt(input({ memoryContext: "MEMORY_FACT" }));
    expect(r.stable).toContain("MEMORY_FACT");
    expect(r.volatile).not.toContain("MEMORY_FACT");
  });
});

// ── plan briefing (plan_mode.dart parity) ───────────────────────────────────

describe("planBriefing", () => {
  it("is empty when plan mode is off", () => {
    expect(planBriefing(false)).toBe("");
  });

  it("carries the read-only research phase text and shell command list", () => {
    const s = planBriefing(true);
    expect(s).toContain("PLAN MODE — READ-ONLY RESEARCH PHASE");
    expect(s).toContain("RESEARCH and PROPOSE");
    // the off-limits shell command list (opencode plan.txt parity)
    expect(s).toContain("no redirects into files");
    expect(s).toContain("`tee`, `sed -i`");
    expect(s).toContain("`mv`, `rm`, `mkdir`, `touch`");
    expect(s).toContain("no `git add/commit/checkout`, no installs");
    // the "asks nothing" rule
    expect(s).toContain(
      "You are NEVER asked for a permission while planning",
    );
    // placeholders never survive (Dart G7 pin)
    expect(s).not.toContain("{PLAN_ROOT}");
    expect(s).not.toContain("{PLAN_SCOPE}");
  });

  it("appears in stable iff planMode is true", () => {
    const off = buildSystemPrompt(input());
    const on = buildSystemPrompt(input({ planMode: true }));
    expect(off.stable).not.toContain("PLAN MODE");
    expect(on.stable).toContain("PLAN MODE — READ-ONLY RESEARCH PHASE");
    expect(off.volatile).toBe(on.volatile);
  });

  it("mid-run transition changes ONLY the plan section (G2 turn-boundary swap)", () => {
    for (const mode of ["auto", "safe", "studio", "drive"] as const) {
      const off = buildSystemPrompt(input({ mode }));
      const on = buildSystemPrompt(input({ mode, planMode: true }));
      const section = planBriefing(true);
      // the section occurs exactly once, spliced in as a standalone section
      expect(on.stable.split(section).length).toBe(2);
      expect(off.stable).not.toContain(section);
      // removing it restores the plan-less stable block byte-for-byte
      expect(on.stable.replace(`\n\n${section}\n\n`, "\n\n")).toBe(off.stable);
    }
  });
});

// ── mode section (AgentModeX port, D5: no device/control references) ────────

describe("modeSection", () => {
  it("safe: read-only label, hint and hard-block list", () => {
    const s = modeSection("safe");
    expect(s).toContain("Access mode: READ-ONLY —");
    expect(s).toContain(
      "Read-only. Asks for permission before every shell, browser, or write action.",
    );
    expect(s).toContain("MODE RESTRICTIONS (Read-Only)");
    expect(s).toContain("HARD-BLOCKED");
    expect(s).toContain("file_write");
  });

  it("auto: general mode, workspace-confined, approvals outside", () => {
    const s = modeSection("auto");
    expect(s).toContain("Access mode: GENERAL —");
    expect(s).toContain(
      "Runs shell and browser freely. Asks before pushing to the repo.",
    );
    expect(s).toContain("OUTSIDE the workspace needs the user's approval");
  });

  it("drive: full access", () => {
    const s = modeSection("drive");
    expect(s).toContain("Access mode: FULL ACCESS —");
    expect(s).toContain(
      "Full autonomous — kuch bhi, kahin bhi, no confirmation.",
    );
  });

  it("studio: workspace + repo", () => {
    const s = modeSection("studio");
    expect(s).toContain("Access mode: STUDIO —");
    expect(s).toContain("workspace AND the connected GitHub repo");
    expect(s).toContain(
      "Asks for a confirmation before publishing or committing.",
    );
  });

  it("every mode produces a non-empty section", () => {
    for (const mode of ["safe", "auto", "drive", "studio"] as const) {
      expect(modeSection(mode).trim()).not.toBe("");
    }
  });
});

// ── volatile composition (volatile-context-last parity) ─────────────────────

describe("volatile composition", () => {
  it("contains the tree summary, todo lines and goal", () => {
    const r = buildSystemPrompt(
      input({
        workspaceTreeSummary: "src/ (3 files)",
        todos: TODOS,
        goal: GOAL,
      }),
    );
    expect(r.volatile).toContain("src/ (3 files)");
    expect(r.volatile).toContain("SESSION TODOS (3 items");
    expect(r.volatile).toContain("- [x] done thing");
    expect(r.volatile).toContain("- [~] live thing");
    expect(r.volatile).toContain("- [ ] later thing");
    expect(r.volatile).toContain("Work through the todo list");
    expect(r.volatile).toContain('ACTIVE GOAL: "ship the thing"');
    expect(r.volatile).toContain("update_goal with progress");
    // none of it may leak into the stable prefix
    expect(r.stable).not.toContain("src/ (3 files)");
    expect(r.stable).not.toContain("done thing");
    expect(r.stable).not.toContain("ship the thing");
  });

  it("singular todo count wording", () => {
    const r = buildSystemPrompt(
      input({ todos: [{ content: "only", status: "pending" }] }),
    );
    expect(r.volatile).toContain("SESSION TODOS (1 item —");
  });

  it("goal notes ride under the goal line", () => {
    const r = buildSystemPrompt(
      input({ goal: { objective: "o", notes: "keep it small" } }),
    );
    expect(r.volatile).toContain('ACTIVE GOAL: "o"');
    expect(r.volatile).toContain("Goal notes: keep it small");
  });

  it("subagent briefing rides in volatile", () => {
    const r = buildSystemPrompt(
      input({ isSubagent: true, subagentBriefing: "Research the flange." }),
    );
    expect(r.volatile).toContain("Research the flange.");
    expect(r.stable).not.toContain("Research the flange.");
  });

  it("isSubagent without a briefing changes nothing", () => {
    const withFlag = buildSystemPrompt(input({ isSubagent: true }));
    const without = buildSystemPrompt(input());
    expect(withFlag.stable).toBe(without.stable);
    expect(withFlag.volatile).toBe(without.volatile);
  });
});

// ── D5: no device/control text anywhere ─────────────────────────────────────

describe("D5 — device/control scrub", () => {
  const modes: SessionMode[] = ["safe", "auto", "drive", "studio"];
  it("stable+volatile never matches /device_|Control mode/i", () => {
    for (const mode of modes) {
      for (const planMode of [false, true]) {
        for (const isSubagent of [false, true]) {
          const r = buildSystemPrompt(
            input({
              mode,
              planMode,
              isSubagent,
              persona: "P",
              skillsCatalog: SKILLS,
              memoryContext: "MEMORY_FACT",
              workspaceTreeSummary: "tree line",
              todos: TODOS,
              goal: GOAL,
              subagentBriefing: isSubagent ? "go" : undefined,
            }),
          );
          expect(`${r.stable}\n${r.volatile}`).not.toMatch(
            /device_|Control mode/i,
          );
        }
      }
    }
  });
});

describe("studio awareness", () => {
  it("tells the agent where cloned repos live", () => {
    const parts = buildSystemPrompt({
      mode: "studio",
      planMode: false,
      isSubagent: false,
      persona: "",
      workspaceFolder: "/workspace",
      workspaceTreeSummary: "",
      skillsCatalog: [],
      memoryContext: "",
      todos: [],
      goal: null,
    });
    expect(parts.stable).toContain("/studio");
  });
});
