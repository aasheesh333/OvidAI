// Task 13 — manifest normalization + CC/Codex/native adapters: the pinned
// case source is the Dart suite (test/claude_plugin_compat_test.dart,
// claude_plugin_json_parity_test.dart, plugin_adapter_e2e_test.dart,
// plugin_capability_inference_test.dart, plugin_digest_stability_test.dart),
// ported field-by-field per AG4 plus the cloud-specific pins from the brief
// (canonical ids, digest projection, device-era capability stripping).

import { afterEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  ManifestError,
  CLOUD_HOOK_EVENTS,
  adaptPlugin,
  canonicalContributionId,
  canonicalHookEvent,
  pluginManifestDigest,
} from "./manifest.js";
import { inferRequestedCapabilities } from "./capabilities.js";
import { contributionsFromManifest } from "./registry.js";
import type {
  NormalizedPluginManifest,
  PluginAgent,
  PluginCommand,
  PluginHook,
  PluginMcpServerContribution,
  PluginSkill,
} from "./manifest.js";

const roots: string[] = [];

afterEach(async () => {
  while (roots.length > 0) {
    await rm(roots.pop()!, { recursive: true, force: true });
  }
});

/** Write a fixture plugin tree into a fresh mkdtemp dir. */
async function makeTree(files: Record<string, string>): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ovid-manifest-test-"));
  roots.push(root);
  for (const [rel, content] of Object.entries(files)) {
    const p = join(root, rel);
    await mkdir(dirname(p), { recursive: true });
    await writeFile(p, content);
  }
  return root;
}

const CC_MANIFEST = JSON.stringify({
  name: "Demo",
  version: "1.2.3",
  author: "Acme",
  description: "demo plugin",
});

function ccTree(extra: Record<string, string> = {}): Record<string, string> {
  return {
    ".claude-plugin/plugin.json": CC_MANIFEST,
    ...extra,
  };
}

function manifestOf(
  overrides: Partial<NormalizedPluginManifest> = {},
): NormalizedPluginManifest {
  return {
    pluginId: "acme/demo",
    version: "1.0.0",
    format: "claudeCode",
    commands: [],
    skills: [],
    agents: [],
    hooks: [],
    mcpServers: [],
    capabilities: [],
    envNames: [],
    warnings: [],
    rootPath: "/tmp/acme/demo",
    ...overrides,
  };
}

describe("canonicalContributionId", () => {
  it("builds the plugin:<id>/<kind>:<name> scheme with hook ordinals", () => {
    expect(canonicalContributionId("acme/demo", "command", "foo")).toBe(
      "plugin:acme/demo/command:foo",
    );
    expect(canonicalContributionId("acme/demo", "skill", "review")).toBe(
      "plugin:acme/demo/skill:review",
    );
    expect(canonicalContributionId("acme/demo", "agent", "coder")).toBe(
      "plugin:acme/demo/agent:coder",
    );
    expect(canonicalContributionId("acme/demo", "mcp", "bar")).toBe(
      "plugin:acme/demo/mcp:bar",
    );
    expect(canonicalContributionId("acme/demo", "setting", "api_key")).toBe(
      "plugin:acme/demo/setting:api_key",
    );
    expect(canonicalContributionId("acme/demo", "hook", "PreToolUse", 0)).toBe(
      "plugin:acme/demo/hook:PreToolUse:0",
    );
    expect(canonicalContributionId("acme/demo", "hook", "Stop", 3)).toBe(
      "plugin:acme/demo/hook:Stop:3",
    );
  });
});

describe("adaptPlugin — Claude-Code bundles", () => {
  it("normalizes commands, .mcp.json and hooks with exact canonical ids", async () => {
    const root = await makeTree(
      ccTree({
        "commands/foo.md": "---\ndescription: Foo command\n---\n\nRun foo.\n",
        ".mcp.json": JSON.stringify({
          mcpServers: {
            bar: {
              command: "node",
              args: ["server.js"],
              env: { TOKEN: "${MCP_TOKEN}" },
            },
          },
        }),
        "hooks/hooks.json": JSON.stringify({
          hooks: {
            PreToolUse: [
              {
                matcher: "Edit",
                hooks: [{ type: "command", command: "echo hi" }],
              },
            ],
          },
        }),
      }),
    );

    const m = await adaptPlugin(root);

    expect(m.pluginId).toBe("acme/demo");
    expect(m.version).toBe("1.2.3");
    expect(m.format).toBe("claudeCode");
    expect(m.rootPath).toBe(root);

    expect(m.commands).toHaveLength(1);
    expect(m.commands[0]).toMatchObject({
      name: "foo",
      description: "Foo command",
      file: "commands/foo.md",
    });

    expect(m.mcpServers).toHaveLength(1);
    expect(m.mcpServers[0]?.name).toBe("bar");
    expect(m.mcpServers[0]?.imported.transport).toBe("stdio");
    expect(m.mcpServers[0]?.imported.command).toBe("node");
    expect(m.mcpServers[0]?.imported.args).toEqual(["server.js"]);
    // `${MCP_TOKEN}` stays literal: the worker environment is never used to
    // resolve plugin-declared credentials at adaptation time.
    expect(m.mcpServers[0]?.imported.env?.TOKEN).toBe("${MCP_TOKEN}");

    expect(m.hooks).toHaveLength(1);
    expect(m.hooks[0]).toMatchObject({
      event: "pre_tool",
      type: "command",
      command: "echo hi",
      canBlock: true,
      ordinal: 0,
    });

    expect(m.envNames).toContain("TOKEN");

    const ids = contributionsFromManifest(m).map((r) => r.canonicalId);
    expect(ids).toContain("plugin:acme/demo/command:foo");
    expect(ids).toContain("plugin:acme/demo/mcp:bar");
    expect(ids).toContain("plugin:acme/demo/hook:pre_tool:0");
  });

  it("parses inline mcpServers and a './.mcp.json' pointer", async () => {
    const inlineRoot = await makeTree(
      ccTree({
        ".claude-plugin/plugin.json": JSON.stringify({
          name: "P",
          author: "a",
          mcpServers: { inline: { command: "node" } },
        }),
      }),
    );
    const inline = await adaptPlugin(inlineRoot);
    expect(inline.mcpServers.map((s) => s.name)).toEqual(["inline"]);
    expect(inline.mcpServers[0]?.imported.transport).toBe("stdio");

    const pointerRoot = await makeTree(
      ccTree({
        ".claude-plugin/plugin.json": JSON.stringify({
          name: "P",
          author: "a",
          mcpServers: "./.mcp.json",
        }),
        ".mcp.json": JSON.stringify({
          mcpServers: {
            pointed: { type: "http", url: "https://mcp.example.com" },
          },
        }),
      }),
    );
    const pointed = await adaptPlugin(pointerRoot);
    expect(pointed.mcpServers.map((s) => s.name)).toEqual(["pointed"]);
    expect(pointed.mcpServers[0]?.imported.transport).toBe("http");
    expect(
      inferRequestedCapabilities(pointed).has("networkConnect"),
    ).toBe(true);
  });

  it("object authors name the publisher (superpowers shape)", async () => {
    const root = await makeTree({
      ".claude-plugin/plugin.json": JSON.stringify({
        name: "superpowers",
        version: "6.4.1",
        author: { name: "Jesse Vincent", email: "jesse@fsck.com" },
      }),
      "skills/using-superpowers/SKILL.md":
        "---\nname: using-superpowers\ndescription: Use superpowers\n---\n\n# Using\n",
    });
    const m = await adaptPlugin(root);
    expect(m.pluginId).toBe("jesse-vincent/superpowers");
    expect(m.skills.map((s) => s.name)).toEqual(["using-superpowers"]);
    expect(m.skills[0]?.file).toBe("skills/using-superpowers/SKILL.md");
  });

  it("namespaces command names by sub-directory so siblings never collide", async () => {
    const root = await makeTree(
      ccTree({
        "commands/git/commit.md": "---\ndescription: c\n---\n\n# body\n",
        "commands/svn/commit.md": "---\ndescription: c\n---\n\n# body\n",
        "commands/top.md": "---\ndescription: c\n---\n\n# body\n",
      }),
    );
    const m = await adaptPlugin(root);
    const names = m.commands.map((c) => c.name);
    expect(names).toEqual(["git-commit", "svn-commit", "top"]);
  });

  it("a plugin.json 'hooks' string is a FILE pointer", async () => {
    const root = await makeTree(
      ccTree({
        ".claude-plugin/plugin.json": JSON.stringify({
          name: "parity",
          version: "1.0.0",
          author: { name: "T", email: "t@t.com" },
          hooks: "./config/my-hooks.json",
        }),
        "config/my-hooks.json": JSON.stringify({
          hooks: {
            PreToolUse: [
              {
                matcher: "Edit",
                hooks: [{ type: "command", command: "echo hi" }],
              },
            ],
          },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks).toHaveLength(1);
    expect(m.hooks[0]?.event).toBe("pre_tool");
    expect(m.hooks[0]?.command).toBe("echo hi");
  });

  it("'commands' may be an array of directory pointers", async () => {
    const root = await makeTree(
      ccTree({
        ".claude-plugin/plugin.json": JSON.stringify({
          name: "parity",
          author: "t",
          commands: ["./extra-a", "./extra-b"],
        }),
        "extra-a/one.md": "---\ndescription: c\n---\n\n# body\n",
        "extra-b/two.md": "---\ndescription: c\n---\n\n# body\n",
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.commands.map((c) => c.name).sort()).toEqual(["one", "two"]);
  });

  it("hook ordinals are per-event, not global", async () => {
    const root = await makeTree(
      ccTree({
        "hooks/hooks.json": JSON.stringify({
          hooks: {
            SessionStart: [
              { matcher: "", hooks: [{ type: "command", command: "echo a" }] },
              { matcher: "", hooks: [{ type: "command", command: "echo b" }] },
            ],
            PreToolUse: [
              { matcher: "", hooks: [{ type: "command", command: "echo c" }] },
            ],
          },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks.map((h) => `${h.event}:${h.ordinal}`)).toEqual([
      "session_start:0",
      "session_start:1",
      "pre_tool:0",
    ]);
  });

  it("a single matcher-object hook event value is wrapped, not dropped", async () => {
    const root = await makeTree(
      ccTree({
        "hooks/hooks.json": JSON.stringify({
          hooks: {
            SessionStart: {
              matcher: "startup",
              hooks: [{ type: "command", command: "echo wrapped" }],
            },
          },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks).toHaveLength(1);
    expect(m.hooks[0]?.command).toBe("echo wrapped");
  });

  it("hook event string shorthand becomes a command hook", async () => {
    const root = await makeTree(
      ccTree({
        "hooks/hooks.json": JSON.stringify({
          hooks: { PreToolUse: "echo checking" },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks).toHaveLength(1);
    expect(m.hooks[0]?.command).toBe("echo checking");
    expect(m.hooks[0]?.canBlock).toBe(true);
  });

  it("prompt hooks are skipped with a warning (only command hooks execute)", async () => {
    const root = await makeTree(
      ccTree({
        "hooks/hooks.json": JSON.stringify({
          hooks: {
            SessionStart: [
              { hooks: [{ type: "prompt", prompt: "think hard" }] },
            ],
          },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks).toHaveLength(0);
    expect(m.warnings.some((w) => w.includes("prompt"))).toBe(true);
  });

  it("missing or malformed author → ManifestError, never a silent install", async () => {
    for (const author of [undefined, 42, ["a", "b"], "  "]) {
      const root = await makeTree({
        ".claude-plugin/plugin.json": JSON.stringify({
          name: "authortest",
          ...(author === undefined ? {} : { author }),
        }),
      });
      await expect(adaptPlugin(root)).rejects.toBeInstanceOf(ManifestError);
    }
  });

  it("SSE servers are accepted as a supported transport", async () => {
    const root = await makeTree(
      ccTree({
        ".mcp.json": JSON.stringify({
          mcpServers: {
            legacy: { type: "sse", url: "https://example.com/sse" },
          },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.mcpServers[0]?.imported.transport).toBe("sse");
    expect(inferRequestedCapabilities(m).has("networkConnect")).toBe(true);
  });
});

describe("canonicalHookEvent (full raw→canonical resolver)", () => {
  it("resolves every cloud event, its CC/legacy spellings, and the Dart extras", () => {
    for (const canonical of CLOUD_HOOK_EVENTS) {
      expect(canonicalHookEvent(canonical)).toBe(canonical);
    }
    // [CC] PascalCase spellings.
    expect(canonicalHookEvent("SessionStart")).toBe("session_start");
    expect(canonicalHookEvent("UserPromptSubmit")).toBe("user_prompt_submit");
    expect(canonicalHookEvent("PreToolUse")).toBe("pre_tool");
    expect(canonicalHookEvent("PostToolUse")).toBe("post_tool");
    expect(canonicalHookEvent("PostToolUseFailure")).toBe("post_tool");
    expect(canonicalHookEvent("Stop")).toBe("stop");
    expect(canonicalHookEvent("SubagentStop")).toBe("subagent_stop");
    expect(canonicalHookEvent("Notification")).toBe("notification");
    // Legacy Ovid aliases.
    expect(canonicalHookEvent("on_session_start")).toBe("session_start");
    expect(canonicalHookEvent("on_pre_request")).toBe("pre_request");
    expect(canonicalHookEvent("on_pre_tool")).toBe("pre_tool");
    expect(canonicalHookEvent("on_post_tool")).toBe("post_tool");
    expect(canonicalHookEvent("on_turn_start")).toBe("user_prompt_submit");
    expect(canonicalHookEvent("on_turn_end")).toBe("stop");
    expect(canonicalHookEvent("subagent_end")).toBe("subagent_stop");
    // Dart-canonical events the cloud engine cut (still resolvable, so the
    // adapter can skip them with a specific loud warning).
    expect(canonicalHookEvent("SessionEnd")).toBe("session_end");
    expect(canonicalHookEvent("PreCompact")).toBe("pre_compact");
    expect(canonicalHookEvent("PostCompact")).toBe("post_compact");
    expect(canonicalHookEvent("SubagentStart")).toBe("subagent_start");
    expect(canonicalHookEvent("permission_request")).toBe("permission_request");
    expect(canonicalHookEvent("PermissionRequest")).toBe("permission_request");
    // Unknown → null.
    expect(canonicalHookEvent("Telepathy")).toBeNull();
    expect(canonicalHookEvent("")).toBeNull();
  });

  it("hook canonical ids and digests are spelling-independent", async () => {
    const bySpellings: Record<string, string> = {};
    const digests: Record<string, string> = {};
    for (const spelling of ["PreToolUse", "pre_tool", "on_pre_tool"]) {
      const root = await makeTree(
        ccTree({
          "hooks/hooks.json": JSON.stringify({
            hooks: { [spelling]: "echo hi" },
          }),
        }),
      );
      const m = await adaptPlugin(root);
      expect(m.hooks).toHaveLength(1);
      expect(m.hooks[0]?.event).toBe("pre_tool");
      const ids = contributionsFromManifest(m)
        .filter((r) => r.kind === "hook")
        .map((r) => r.canonicalId);
      expect(ids).toEqual(["plugin:acme/demo/hook:pre_tool:0"]);
      digests[spelling] = pluginManifestDigest(m);
    }
    expect(digests.pre_tool).toBe(digests.PreToolUse);
    expect(digests.on_pre_tool).toBe(digests.PreToolUse);
  });

  it("permission_request declarations are skipped with a loud pre_tool-gate warning", async () => {
    const root = await makeTree(
      ccTree({
        "hooks/hooks.json": JSON.stringify({
          hooks: { PermissionRequest: "echo gate" },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks).toHaveLength(0);
    const w = m.warnings.find((x) => x.includes("permission_request"));
    expect(w).toBeDefined();
    expect(w).toMatch(/pre_tool/); // documents the alternative gate
    expect(inferRequestedCapabilities(m).has("hooksBlock")).toBe(false);
  });

  it("cloud-unsupported events are skipped with a warning", async () => {
    const root = await makeTree(
      ccTree({
        "hooks/hooks.json": JSON.stringify({
          hooks: {
            PreCompact: "echo compact",
            Telepathy: "echo nope",
          },
        }),
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks).toHaveLength(0);
    expect(m.warnings.some((x) => x.includes("PreCompact"))).toBe(true);
    expect(m.warnings.some((x) => x.includes("Telepathy"))).toBe(true);
  });

  it("a corrupt hooks.json is loud, not silently disabled", async () => {
    const root = await makeTree(
      ccTree({
        "hooks/hooks.json": "{ not json",
      }),
    );
    const m = await adaptPlugin(root);
    expect(m.hooks).toHaveLength(0);
    expect(
      m.warnings.some((x) => x.includes("hooks.json") && x.includes("valid JSON")),
    ).toBe(true);
  });
});

describe("adaptPlugin — Codex trees", () => {
  function codexTree(extra: Record<string, string> = {}): Record<string, string> {
    return {
      "config.toml": [
        'name = "Codex Kit"',
        'version = "0.9.0"',
        "",
        "[environment]",
        'API_KEY = "value"',
        "",
        "[mcp_servers.remote]",
        'url = "https://mcp.example.com"',
        'type = "http"',
        "",
        "[[hooks.SessionStart]]",
        'matcher = ""',
        "",
        "[[hooks.SessionStart.hooks]]",
        'type = "command"',
        'command = "echo boot"',
        "",
      ].join("\n"),
      ".codex-plugin/plugin.json": JSON.stringify({
        name: "Codex Kit Manifest",
        author: "codex-author",
        version: "1.0.0",
        skills: "./skills/",
      }),
      "skills/using/SKILL.md":
        "---\nname: using\ndescription: Use it\n---\n\n# Using\n",
      ...extra,
    };
  }

  it("normalizes identity, skills, mcp, hooks and [environment] names", async () => {
    const root = await makeTree(codexTree());
    const m = await adaptPlugin(root);

    expect(m.format).toBe("codex");
    // config.toml name wins over the manifest; publisher from the manifest
    // author (no TOML publisher declared).
    expect(m.pluginId).toBe("codex-author/codex-kit");
    expect(m.version).toBe("0.9.0");
    expect(m.skills.map((s) => s.name)).toEqual(["using"]);
    expect(m.mcpServers.map((s) => s.name)).toEqual(["remote"]);
    expect(m.mcpServers[0]?.imported.transport).toBe("http");
    expect(m.hooks).toHaveLength(1);
    expect(m.hooks[0]).toMatchObject({
      event: "session_start",
      command: "echo boot",
      canBlock: false,
    });
    expect(m.envNames).toContain("API_KEY");
    expect(inferRequestedCapabilities(m).has("environmentRead")).toBe(true);
  });

  it("numeric manifest version is stringified, not cast-thrown", async () => {
    const root = await makeTree({
      ".codex-plugin/plugin.json": JSON.stringify({
        name: "versiontest",
        version: 2,
        author: "tester",
      }),
    });
    const m = await adaptPlugin(root);
    expect(m.version).toBe("2");
  });

  it("skills pointer cannot escape the plugin tree", async () => {
    const root = await makeTree({
      ".codex-plugin/plugin.json": JSON.stringify({
        name: "pointertest",
        author: "tester",
        skills: "../outside",
      }),
    });
    const m = await adaptPlugin(root);
    expect(m.skills).toHaveLength(0);
  });

  it("stock configs with no name derive identity from the directory", async () => {
    const root = await makeTree({
      "config.toml": '[mcp_servers.s]\ncommand = "node"\n',
    });
    const m = await adaptPlugin(root);
    expect(m.format).toBe("codex");
    expect(m.pluginId).toBe(`codex/${basenameSlug(root)}`);
    expect(m.mcpServers.map((s) => s.name)).toEqual(["s"]);
  });
});

function basenameSlug(p: string): string {
  const base = p.split("/").filter(Boolean).pop() ?? "plugin";
  return base
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

describe("adaptPlugin — native manifests", () => {
  it("a bare plugin.json adapts as format 'native'", async () => {
    const root = await makeTree({
      "plugin.json": JSON.stringify({
        name: "Native",
        author: "ovid",
        version: "3.0.0",
      }),
      "commands/run.md": "---\ndescription: Run\n---\n\n# Run\n",
    });
    const m = await adaptPlugin(root);
    expect(m.format).toBe("native");
    expect(m.pluginId).toBe("ovid/native");
    expect(m.version).toBe("3.0.0");
    expect(m.commands.map((c) => c.name)).toEqual(["run"]);
  });

  it("unknown and device-era capability declarations are stripped with warnings", async () => {
    const root = await makeTree({
      "plugin.json": JSON.stringify({
        name: "N",
        author: "a",
        version: "1",
        capabilities: [
          "workspaceRead",
          "sessionRead",
          "deviceControl",
          "telepathy",
        ],
      }),
    });
    const m = await adaptPlugin(root);
    expect(m.capabilities).toEqual(["workspaceRead"]);
    expect(m.warnings.some((w) => w.includes("sessionRead"))).toBe(true);
    expect(m.warnings.some((w) => w.includes("deviceControl"))).toBe(true);
    expect(m.warnings.some((w) => w.includes("telepathy"))).toBe(true);
    // Explicitly declared surviving capabilities are retained by inference.
    expect(inferRequestedCapabilities(m).has("workspaceRead")).toBe(true);
  });

  it("missing author → ManifestError", async () => {
    const root = await makeTree({
      "plugin.json": JSON.stringify({ name: "anon", version: "1" }),
    });
    await expect(adaptPlugin(root)).rejects.toBeInstanceOf(ManifestError);
  });
});

describe("adaptPlugin — routing", () => {
  it("prefers the Claude adapter when both manifests exist", async () => {
    const root = await makeTree({
      ".claude-plugin/plugin.json": JSON.stringify({
        name: "superpowers",
        author: "Jesse Vincent",
      }),
      ".codex-plugin/plugin.json": JSON.stringify({
        name: "superpowers",
        author: "Jesse Vincent",
      }),
    });
    const m = await adaptPlugin(root);
    expect(m.format).toBe("claudeCode");
    expect(m.pluginId).toBe("jesse-vincent/superpowers");
  });

  it("routes a Codex-only tree to the Codex adapter", async () => {
    const root = await makeTree({
      ".codex-plugin/plugin.json": JSON.stringify({
        name: "superpowers",
        version: "6.4.1",
        author: "Jesse Vincent",
      }),
    });
    const m = await adaptPlugin(root);
    expect(m.format).toBe("codex");
    expect(m.pluginId).toBe("jesse-vincent/superpowers");
  });
});

describe("pluginManifestDigest", () => {
  const command: PluginCommand = {
    name: "foo",
    description: "Foo command",
    file: "commands/foo.md",
  };
  const skill: PluginSkill = {
    name: "using",
    description: "Use it",
    file: "skills/using/SKILL.md",
  };
  const agent: PluginAgent = { name: "coder", file: "agents/coder.md" };
  const hook: PluginHook = {
    event: "PreToolUse",
    type: "command",
    command: "echo hi",
    canBlock: true,
    ordinal: 0,
  };
  const mcp: PluginMcpServerContribution = {
    name: "bar",
    imported: {
      name: "bar",
      transport: "stdio",
      command: "node",
      args: ["server.js"],
      env: { TOKEN: "${MCP_TOKEN}" },
    },
  };

  it("is stable across rootPath and version changes", () => {
    const a = manifestOf({
      commands: [command],
      skills: [skill],
      agents: [agent],
      hooks: [hook],
      mcpServers: [mcp],
      capabilities: ["workspaceRead", "mcpRegister"],
      envNames: ["TOKEN"],
      rootPath: "/staging/uuid",
      version: "1.0.0",
    });
    const b = manifestOf({
      commands: [command],
      skills: [skill],
      agents: [agent],
      hooks: [hook],
      mcpServers: [mcp],
      capabilities: ["mcpRegister", "workspaceRead"], // order must not matter
      envNames: ["TOKEN"],
      rootPath: "/workspace/.ovid/plugins/acme/demo/1.0.0",
      version: "2.0.0",
    });
    expect(pluginManifestDigest(b)).toBe(pluginManifestDigest(a));
    expect(a.rootPath).not.toBe(b.rootPath);
    expect(a.version).not.toBe(b.version);
  });

  it("changes when a command is added", () => {
    const base = manifestOf({ commands: [command] });
    const grown = manifestOf({
      commands: [command, { name: "bar", file: "commands/bar.md" }],
    });
    expect(pluginManifestDigest(grown)).not.toBe(pluginManifestDigest(base));
  });

  it("ignores warnings churn (advisory, parser-volatile)", () => {
    const a = manifestOf({ commands: [command] });
    const b = manifestOf({
      commands: [command],
      warnings: ["advisory note from a newer parser"],
    });
    expect(pluginManifestDigest(b)).toBe(pluginManifestDigest(a));
  });

  it("end-to-end: same tree at two locations digests identically", async () => {
    const files = ccTree({
      "commands/foo.md": "---\ndescription: Foo\n---\n\nRun foo.\n",
    });
    const rootA = await makeTree(files);
    const rootB = await makeTree(files);
    const a = await adaptPlugin(rootA);
    const b = await adaptPlugin(rootB);
    expect(a.rootPath).not.toBe(b.rootPath);
    expect(pluginManifestDigest(b)).toBe(pluginManifestDigest(a));

    await writeFile(join(rootB, "commands/extra.md"), "# extra\n");
    const grown = await adaptPlugin(rootB);
    expect(pluginManifestDigest(grown)).not.toBe(
      pluginManifestDigest(a),
    );
  });
});

describe("inferRequestedCapabilities", () => {
  it("derives the minimum set from contributions (never blanket)", () => {
    const commandHook: PluginHook = {
      event: "PreToolUse",
      type: "command",
      command: "rm -rf build",
      canBlock: true,
      ordinal: 0,
    };
    const m = manifestOf({
      commands: [{ name: "run", file: "commands/run.md" }],
      hooks: [commandHook],
    });
    const caps = inferRequestedCapabilities(m);
    expect(caps.has("workspaceRead")).toBe(true);
    expect(caps.has("hooksObserve")).toBe(true);
    expect(caps.has("hooksBlock")).toBe(true);
    expect(caps.has("shellExecute")).toBe(true);
    // Not derivable from the contribution shape:
    expect(caps.has("workspaceWrite")).toBe(false);
    expect(caps.has("networkConnect")).toBe(false);
  });

  it("stdio mcp → mcpRegister + processSpawn; env names → environmentRead", () => {
    const m = manifestOf({
      mcpServers: [
        {
          name: "filesystem",
          imported: { name: "filesystem", transport: "stdio", command: "node" },
        },
      ],
      envNames: ["MCP_TOKEN"],
    });
    const caps = inferRequestedCapabilities(m);
    expect(caps.has("mcpRegister")).toBe(true);
    expect(caps.has("processSpawn")).toBe(true);
    expect(caps.has("environmentRead")).toBe(true);
    expect(caps.has("networkConnect")).toBe(false);
  });

  it("http and sse mcp → networkConnect", () => {
    for (const transport of ["http", "sse"] as const) {
      const m = manifestOf({
        mcpServers: [
          {
            name: "remote",
            imported: { name: "remote", transport, url: "https://x.example" },
          },
        ],
      });
      expect(inferRequestedCapabilities(m).has("networkConnect")).toBe(true);
    }
  });

  it("retains explicitly declared capabilities (e.g. workspaceWrite)", () => {
    const m = manifestOf({ capabilities: ["workspaceWrite"] });
    expect(inferRequestedCapabilities(m).has("workspaceWrite")).toBe(true);
  });

  it("observe-only hooks never request hooksBlock or shellExecute", () => {
    const m = manifestOf({
      hooks: [
        {
          event: "SessionStart",
          type: "command",
          command: "echo hi",
          canBlock: false,
          ordinal: 0,
        },
      ],
    });
    const caps = inferRequestedCapabilities(m);
    expect(caps.has("hooksObserve")).toBe(true);
    expect(caps.has("shellExecute")).toBe(true);
    expect(caps.has("hooksBlock")).toBe(false);
  });
});
