// P3 Task 17 — SKILL.md loader parity tests (Dart lib/core/skills.dart,
// test/skills_parsing_test.dart, test/skill_hot_reload_test.dart,
// test/skills_discovery_identity_regression_test.dart).
//
// Cloud discovery is deliberately narrower than Dart's root list: only
// `.dsh/skills/<name>/SKILL.md` (bundle) and `.dsh/skills/<name>.md` (flat)
// per the plan brief. Supporting-file inlining / readSupportingFile /
// scanBundleFiles are deleted-with-comment (the landed Skill port has no
// dirPath/supportingFiles and the tool contract returns the body verbatim).

import { describe, expect, it } from "vitest";

import { createMemoryStateStore } from "./ports.js";
import type { SandboxPort } from "./ports.js";
import { isToolPermitted, type RosterContext } from "./roster.js";
import {
  createSkillCatalog,
  parseSkillFrontmatter,
  skillAllowedTools,
} from "./skillsLoader.js";
import { createSkillTool } from "./tools/skills.js";
import type { ToolContext } from "./types.js";

/** A SandboxPort fake serving an in-memory workspace (workspace-relative paths). */
function fakeSandbox(initial: Record<string, string> = {}) {
  const files = new Map<string, string>(Object.entries(initial));
  const sandbox: SandboxPort = {
    async exec() {
      throw new Error("not used");
    },
    async killCall() {},
    async readFile(_userId, path) {
      const content = files.get(path);
      if (content === undefined) throw new Error(`no such file: ${path}`);
      return content;
    },
    async writeFile(_userId, path, content) {
      files.set(path, content);
    },
    async exists(_userId, path) {
      if (files.has(path)) return true;
      const prefix = path.endsWith("/") ? path : `${path}/`;
      return [...files.keys()].some((f) => f.startsWith(prefix));
    },
    async listDir(_userId, path) {
      const prefix = path === "" ? "" : path.endsWith("/") ? path : `${path}/`;
      const entries = new Set<string>();
      for (const file of files.keys()) {
        if (!file.startsWith(prefix)) continue;
        const rest = file.slice(prefix.length);
        if (rest === "") continue;
        entries.add(rest.split("/")[0]!);
      }
      if (entries.size === 0) throw new Error(`no such directory: ${path}`);
      return [...entries];
    },
    async jobStart() {
      throw new Error("not used");
    },
    async jobOutput() {
      throw new Error("not used");
    },
    async jobList() {
      return [];
    },
    async jobKill() {},
  };
  return { sandbox, files };
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

function rosterContext(activeSkillScopes: string[]): RosterContext {
  return {
    mode: "auto",
    planMode: false,
    isSubagent: false,
    memoryEnabled: true,
    githubConnected: true,
    preset: null,
    activeSkillScopes,
  };
}

describe("parseSkillFrontmatter", () => {
  it("returns attrs {} for a malformed fence (Dart stripMarkdownFrontmatter parity)", () => {
    const raw = "---\nname: broken\nNO CLOSING FENCE";
    expect(parseSkillFrontmatter(raw)).toEqual({ attrs: {}, body: raw });
  });

  it("leaves a document without frontmatter untouched", () => {
    expect(parseSkillFrontmatter("Just a body\n")).toEqual({
      attrs: {},
      body: "Just a body\n",
    });
  });

  it("parses folded block scalars by joining indented lines with spaces", () => {
    const { attrs } = parseSkillFrontmatter(
      "---\nname: fold\ndescription: >\n  Cut a release\n  with care.\n---\nBODY\n",
    );
    expect(attrs.description).toBe("Cut a release with care.");
    expect(attrs.name).toBe("fold");
  });

  it("parses literal block scalars preserving newlines", () => {
    const { attrs } = parseSkillFrontmatter(
      "---\nname: literal\ndescription: |\n  line one\n  line two\n---\nBODY\n",
    );
    expect(attrs.description).toBe("line one\nline two");
  });

  it("parses a bare key + indented block list", () => {
    const { attrs } = parseSkillFrontmatter(
      "---\nname: tools\nallowed-tools:\n  - Read\n  - Bash\n---\nBODY\n",
    );
    expect(attrs["allowed-tools"]).toBe("Read\nBash");
  });

  it("keeps quoted values and values containing colons", () => {
    const { attrs } = parseSkillFrontmatter(
      '---\nname: "Hindi Translator"\ndescription: "a: b"\nwhenToUse: use when: needed\n---\nBODY\n',
    );
    expect(attrs.name).toBe("Hindi Translator");
    expect(attrs.description).toBe("a: b");
    expect(attrs.whenToUse).toBe("use when: needed");
  });
});

describe("createSkillCatalog discovery", () => {
  it("discovers bundle SKILL.md and flat <name>.md", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/bundle/SKILL.md": "---\nname: bundle-skill\n---\nBUNDLE",
      ".dsh/skills/flat.md": "---\nname: flat-skill\n---\nFLAT",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    const list = await catalog.list("s1");
    expect(list.map((s) => s.name).sort()).toEqual(["bundle-skill", "flat-skill"]);
  });

  it("defaults the name to the bundle directory / flat filename when unnamed", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/review/SKILL.md": "Review the changed files.",
      ".dsh/skills/notes.md": "Some notes.",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    const list = await catalog.list("s1");
    expect(list.map((s) => s.name).sort()).toEqual(["notes", "review"]);
    expect((await catalog.load("review", "s1"))?.content).toBe(
      "Review the changed files.",
    );
  });

  it("skips known root documentation files but keeps custom .md files", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/AGENTS.md": "---\nname: agents-doc\n---\nAGENTS",
      ".dsh/skills/README.md": "---\nname: readme-doc\n---\nREADME",
      ".dsh/skills/CHANGELOG.md": "---\nname: changelog-doc\n---\nCHANGELOG",
      ".dsh/skills/CONTRIBUTING.md": "---\nname: contributing-doc\n---\nCONTRIBUTING",
      ".dsh/skills/CODE_OF_CONDUCT.md": "---\nname: conduct-doc\n---\nCONDUCT",
      ".dsh/skills/LICENSE.md": "---\nname: license-doc\n---\nLICENSE",
      ".dsh/skills/SECURITY.md": "---\nname: security-doc\n---\nSECURITY",
      ".dsh/skills/custom-skill.md": "---\nname: custom-skill\n---\nCUSTOM",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect((await catalog.list("s1")).map((s) => s.name)).toEqual([
      "custom-skill",
    ]);
  });

  it("discovers nested markdown below the root (depth > 0 is not doc-skipped)", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/notes/README.md": "---\nname: nested-note\n---\nNESTED",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect((await catalog.list("s1")).map((s) => s.name)).toEqual([
      "nested-note",
    ]);
  });

  it("does NOT discover AGENT.md bundles (agent kind is P6/T20)", async () => {
    // Dart's `_scanDir` also parses `<dir>/AGENT.md` as an agent contribution.
    // The cloud Skill port has no agent kind, so only SKILL.md bundles are
    // discovered (delete-with-comment in skillsLoader.ts).
    const { sandbox } = fakeSandbox({
      ".dsh/skills/persona/AGENT.md": "---\nname: persona-agent\n---\nAGENT",
      ".dsh/skills/bundle/SKILL.md": "---\nname: bundle-skill\n---\nBUNDLE",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect((await catalog.list("s1")).map((s) => s.name)).toEqual([
      "bundle-skill",
    ]);
  });

  it("bundle beats flat on a name collision", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/review/SKILL.md": "---\nname: review\n---\nBUNDLE CONTENT",
      ".dsh/skills/review.md": "---\nname: review\n---\nFLAT CONTENT",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    const list = await catalog.list("s1");
    expect(list).toHaveLength(1);
    expect((await catalog.load("review", "s1"))?.content).toBe("BUNDLE CONTENT");
  });

  it("dedupes first-wins and does not make an overlapping scan ambiguous", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/review/SKILL.md": "---\nname: review\n---\nONE",
      ".dsh/skills/other/review/SKILL.md": "---\nname: review\n---\nTWO",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect(await catalog.list("s1")).toHaveLength(1);
    expect((await catalog.load("review", "s1"))?.content).toBe("ONE");
  });

  it("discards a skill whose body is empty", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/empty/SKILL.md": "---\nname: empty\n---\n   \n",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect(await catalog.list("s1")).toEqual([]);
  });

  it("is case-insensitive on load (Dart SkillService.find parity)", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/tip/SKILL.md": "---\nname: Tip\n---\nTIP",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect((await catalog.load("tip", "s1"))?.name).toBe("Tip");
  });

  it("picks up an edited SKILL.md on the next load (hot reload, no cache)", async () => {
    const { sandbox, files } = fakeSandbox({
      ".dsh/skills/tip/SKILL.md":
        "---\nname: tip\ndescription: A tip\n---\n\nVERSION ONE\n",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect((await catalog.load("tip", "s1"))?.content).toContain("VERSION ONE");

    files.set(
      ".dsh/skills/tip/SKILL.md",
      "---\nname: tip\ndescription: A tip\n---\n\nVERSION TWO\n",
    );
    expect((await catalog.load("tip", "s1"))?.content).toContain("VERSION TWO");
  });
});

describe("frontmatter flags + allowed-tools", () => {
  it("disable-model-invocation: true → modelInvocable false; absent stays true", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/hidden/SKILL.md":
        "---\nname: hidden\ndisable-model-invocation: true\n---\nHIDDEN",
      ".dsh/skills/visible/SKILL.md": "---\nname: visible\n---\nVISIBLE",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    const byName = new Map((await catalog.list("s1")).map((s) => [s.name, s]));
    expect(byName.get("hidden")?.modelInvocable).toBe(false);
    expect(byName.get("visible")?.modelInvocable).toBe(true);
  });

  it("user-invocable: false → userInvocable false; absent stays true", async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/manual/SKILL.md":
        "---\nname: manual\nuser-invocable: false\n---\nMANUAL",
      ".dsh/skills/open/SKILL.md": "---\nname: open\n---\nOPEN",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    const byName = new Map((await catalog.list("s1")).map((s) => [s.name, s]));
    expect(byName.get("manual")?.userInvocable).toBe(false);
    expect(byName.get("open")?.userInvocable).toBe(true);
  });

  it('parses inline comma/bracket allowed-tools: "Bash, Edit" and [run_shell, file_read]', async () => {
    const { sandbox } = fakeSandbox({
      ".dsh/skills/a/SKILL.md":
        '---\nname: a\nallowed-tools: "Bash, Edit"\n---\nA',
      ".dsh/skills/b/SKILL.md":
        "---\nname: b\nallowed-tools: [run_shell, file_read]\n---\nB",
    });
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    expect((await catalog.load("a", "s1"))?.allowedTools).toEqual([
      "Bash",
      "Edit",
    ]);
    expect((await catalog.load("b", "s1"))?.allowedTools).toEqual([
      "run_shell",
      "file_read",
    ]);
  });

  it('skillAllowedTools expands "Bash, Edit" through nativeToolsFor', async () => {
    const skill = {
      name: "locked",
      description: "",
      whenToUse: "",
      content: "",
      path: ".dsh/skills/locked",
      allowedTools: ["Bash", "Edit"],
    };
    expect(skillAllowedTools(skill)).toEqual([
      "run_shell",
      "job_start",
      "job_output",
      "job_list",
      "job_kill",
      "fs_edit",
    ]);
  });
});

describe("skill tool", () => {
  function setup(initial: Record<string, string>) {
    const { sandbox } = fakeSandbox(initial);
    const catalog = createSkillCatalog({ sandbox, userId: "u1" });
    const state = createMemoryStateStore();
    const activations: Array<{ sessionId: string; scopes: string[] }> = [];
    const tool = createSkillTool({
      catalog,
      async onActivate(sessionId, scopes) {
        activations.push({ sessionId, scopes });
        await state.patch(sessionId, { activeSkillScopes: scopes });
      },
    });
    return { tool, state, activations };
  }

  it("unknown name lists the available model-invocable skills", async () => {
    const { tool } = setup({
      ".dsh/skills/locked/SKILL.md":
        "---\nname: locked\ndescription: Read-only helper\nallowed-tools: Read, Glob\n---\nOnly read things.",
      ".dsh/skills/hidden/SKILL.md":
        "---\nname: hidden\ndisable-model-invocation: true\n---\nHIDDEN",
    });
    const res = await tool.execute({ name: "nope" }, ctx("s1"));
    expect(res.isError).toBe(true);
    expect(res.content).toContain('No skill named "nope"');
    expect(res.content).toContain("locked");
    // A model-hidden skill is not advertised.
    expect(res.content).not.toContain("hidden");
  });

  it("returns the skill body and calls onActivate with the expanded scopes", async () => {
    const { tool, state, activations } = setup({
      ".dsh/skills/locked/SKILL.md":
        "---\nname: locked\ndescription: Read-only helper\nallowed-tools: Read, Glob\n---\nOnly read things.",
    });
    const res = await tool.execute({ name: "locked" }, ctx("s1"));
    expect(res.isError).toBeUndefined();
    expect(res.content).toContain("<skill_content>");
    expect(res.content).toContain("Only read things.");
    expect(activations).toEqual([
      {
        sessionId: "s1",
        scopes: ["file_read", "read_image", "read_attachment", "fs_glob"],
      },
    ]);
    expect((await state.get("s1")).activeSkillScopes).toEqual([
      "file_read",
      "read_image",
      "read_attachment",
      "fs_glob",
    ]);
  });

  it("a skill without allowed-tools CLEARS the scope (patches [])", async () => {
    const { tool, state } = setup({
      ".dsh/skills/open/SKILL.md":
        "---\nname: open\ndescription: Free helper\n---\nDo anything.",
    });
    await state.patch("s1", { activeSkillScopes: ["fs_edit"] });
    const res = await tool.execute({ name: "open" }, ctx("s1"));
    expect(res.content).toContain("Do anything.");
    expect((await state.get("s1")).activeSkillScopes).toEqual([]);
  });

  it("the persisted scopes narrow the next roster while skill itself survives", async () => {
    const { tool, state } = setup({
      ".dsh/skills/locked/SKILL.md":
        "---\nname: locked\nallowed-tools: Read, Glob\n---\nOnly read things.",
    });
    await tool.execute({ name: "locked" }, ctx("s1"));
    const scopes = (await state.get("s1")).activeSkillScopes;
    expect(isToolPermitted("file_write", rosterContext(scopes))).toBe(false);
    expect(isToolPermitted("run_shell", rosterContext(scopes))).toBe(false);
    expect(isToolPermitted("file_read", rosterContext(scopes))).toBe(true);
    expect(isToolPermitted("fs_glob", rosterContext(scopes))).toBe(true);
    expect(isToolPermitted("skill", rosterContext(scopes))).toBe(true);
  });

  it("substitutes $1/$ARGUMENTS from input/arguments before wrapping", async () => {
    const { tool } = setup({
      ".dsh/skills/fixer/SKILL.md":
        "---\nname: fixer\n---\nFix $1 in $2; args=$ARGUMENTS",
    });
    const res = await tool.execute(
      { name: "fixer", input: "auth login" },
      ctx("s1"),
    );
    expect(res.content).toContain("Fix auth in login; args=auth login");
  });

  it("requires a name", async () => {
    const { tool } = setup({});
    expect((await tool.execute({}, ctx("s1"))).content).toBe(
      "skill name is required",
    );
  });
});
