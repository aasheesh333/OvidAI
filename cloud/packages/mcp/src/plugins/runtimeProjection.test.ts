// UNEXECUTED per /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// These tests are source-only until the user lifts the heavy-verification pause.

import { describe, expect, it } from "vitest";

import type { ApprovedSource } from "./admission.js";
import { PLUGIN_CAPABILITIES } from "./capabilities.js";
import type { ApprovedContribution } from "./contributions.js";
import type { PluginGrantInput } from "./grants.js";
import {
  APPROVED_RUNTIME_LIMITS,
  ApprovedPluginRuntimeProjectionError,
  projectApprovedPluginRuntime,
  replaceApprovedPluginRuntimeProjection,
  type ApprovedRuntimeInstallation,
  type ApprovedRuntimeProjectionErrorCode,
  type ApprovedRuntimeProjectionInput,
} from "./runtimeProjection.js";

const DIGEST = "sha256:approved-content";

function source(overrides: Partial<ApprovedSource> = {}): ApprovedSource {
  return {
    approvedSourceId: "approved-source-a",
    userId: "user-a",
    canonicalSource: "github:acme/demo",
    resolvedRevision: "0123456789abcdef",
    digest: DIGEST,
    provenance: {
      kind: "github",
      githubRepo: "acme/demo",
      revision: "0123456789abcdef",
    },
    validationState: "validated",
    approvalState: "approved",
    approvedCapabilities: [...PLUGIN_CAPABILITIES],
    ...overrides,
  };
}

function grant(overrides: Partial<PluginGrantInput> = {}): PluginGrantInput {
  return {
    capabilities: [...PLUGIN_CAPABILITIES],
    envNames: ["API_TOKEN", "Authorization"],
    manifestDigest: DIGEST,
    allowDependencyScripts: false,
    ...overrides,
  };
}

function installation(
  overrides: Partial<ApprovedRuntimeInstallation> = {},
): ApprovedRuntimeInstallation {
  return {
    installationId: "installation-a",
    pluginId: "acme/demo",
    contentRoot: "/jail/plugins/acme/demo/1.0.0",
    generation: 3,
    approvedSource: source(),
    grant: grant(),
    ...overrides,
  };
}

function contribution(
  overrides: Partial<ApprovedContribution> = {},
): ApprovedContribution {
  return {
    canonicalId: "plugin:acme/demo/command:review",
    kind: "command",
    pluginId: "acme/demo",
    name: "review",
    rootPath: "/jail/plugins/acme/demo/1.0.0",
    data: { file: "commands/review.md", description: "Review the workspace" },
    userId: "user-a",
    installationId: "installation-a",
    approvedSourceId: "approved-source-a",
    digest: DIGEST,
    generation: 3,
    active: true,
    ...overrides,
  };
}

function skill(overrides: Partial<ApprovedContribution> = {}): ApprovedContribution {
  return contribution({
    canonicalId: "plugin:acme/demo/skill:review",
    kind: "skill",
    name: "review",
    data: { file: "skills/review/SKILL.md", description: "Review skill" },
    ...overrides,
  });
}

function agent(overrides: Partial<ApprovedContribution> = {}): ApprovedContribution {
  return contribution({
    canonicalId: "plugin:acme/demo/agent:helper",
    kind: "agent",
    name: "helper",
    data: { file: "agents/helper.md", description: "Helper agent" },
    ...overrides,
  });
}

function hook(overrides: Partial<ApprovedContribution> = {}): ApprovedContribution {
  return contribution({
    canonicalId: "plugin:acme/demo/hook:pre_tool:0",
    kind: "hook",
    name: "pre_tool",
    data: {
      type: "command",
      command: "node approved-hook.js",
      canBlock: true,
      ordinal: 0,
    },
    ...overrides,
  });
}

function resource(
  overrides: Partial<ApprovedContribution> = {},
): ApprovedContribution {
  return contribution({
    canonicalId: "plugin:acme/demo/resource:icon",
    kind: "resource",
    name: "icon",
    data: { file: "resources/icon.svg", mimeType: "image/svg+xml" },
    ...overrides,
  });
}

function stdioMcp(
  overrides: Partial<ApprovedContribution> = {},
): ApprovedContribution {
  return contribution({
    canonicalId: "plugin:acme/demo/mcp:local",
    kind: "mcp",
    name: "local",
    data: {
      imported: {
        name: "local",
        transport: "stdio",
        command: "node",
        args: ["server.js"],
        env: { API_TOKEN: "pasted-secret" },
        headers: { Authorization: "Bearer pasted-secret" },
      },
    },
    ...overrides,
  });
}

function remoteMcp(
  overrides: Partial<ApprovedContribution> = {},
): ApprovedContribution {
  return contribution({
    canonicalId: "plugin:acme/demo/mcp:remote",
    kind: "mcp",
    name: "remote",
    data: {
      imported: {
        name: "remote",
        transport: "http",
        url: "https://mcp.example.test/endpoint",
      },
    },
    ...overrides,
  });
}

function input(
  contributions: ApprovedContribution[] = [contribution()],
  overrides: Partial<ApprovedRuntimeProjectionInput> = {},
): ApprovedRuntimeProjectionInput {
  return {
    userId: "user-a",
    configGeneration: 7,
    expectedConfigGeneration: 7,
    installations: [installation()],
    contributions,
    ...overrides,
  };
}

function validInputForUser(
  userId: string,
  configGeneration = 7,
): ApprovedRuntimeProjectionInput {
  const installationId = `installation-${userId}`;
  const approvedSourceId = `approved-source-${userId}`;
  const contentRoot = `/jail/users/${userId}/plugins/acme/demo/1.0.0`;
  return input([
    contribution({
      userId,
      installationId,
      approvedSourceId,
      rootPath: contentRoot,
    }),
  ], {
    userId,
    configGeneration,
    expectedConfigGeneration: configGeneration,
    installations: [
      installation({
        installationId,
        contentRoot,
        approvedSource: source({ userId, approvedSourceId }),
      }),
    ],
  });
}

function expectDenied(
  operation: () => unknown,
  code: ApprovedRuntimeProjectionErrorCode,
): void {
  try {
    operation();
  } catch (error) {
    expect(error).toBeInstanceOf(ApprovedPluginRuntimeProjectionError);
    expect(error).toMatchObject({ code });
    return;
  }
  throw new Error(`Expected projection denial: ${code}`);
}

describe("approved plugin runtime projection", () => {
  it("projects every supported kind with exact approval and per-user generation metadata", () => {
    const projected = projectApprovedPluginRuntime(
      input([contribution(), skill(), hook(), resource(), agent(), stdioMcp()]),
    );

    expect(projected.userId).toBe("user-a");
    expect(projected.configGeneration).toBe(7);
    expect(projected.commands).toHaveLength(1);
    expect(projected.skills).toHaveLength(1);
    expect(projected.hooks).toHaveLength(1);
    expect(projected.resources).toHaveLength(1);
    expect(projected.agents).toHaveLength(1);
    expect(projected.mcp).toHaveLength(1);
    expect(projected.hooks[0]).toMatchObject({
      event: "pre_tool",
      type: "command",
      command: "node approved-hook.js",
      canBlock: true,
      ordinal: 0,
    });
    expect(projected.resources[0]?.uri).toBe(
      "plugin://installation-a/plugin:acme/demo/resource:icon/resources/icon.svg",
    );
    expect(projected.mcp[0]).toMatchObject({
      transport: "stdio",
      command: "node",
      args: ["server.js"],
      envNames: ["API_TOKEN"],
      headerNames: ["Authorization"],
    });

    const all = [
      ...projected.hooks,
      ...projected.skills,
      ...projected.commands,
      ...projected.resources,
      ...projected.agents,
      ...projected.mcp,
    ];
    for (const entry of all) {
      expect(entry).toMatchObject({
        installationId: "installation-a",
        approvedSourceId: "approved-source-a",
        digest: DIGEST,
        generation: 3,
      });
    }
    expect(projected.secretScopes).toEqual([
      {
        userId: "user-a",
        configGeneration: 7,
        installationId: "installation-a",
        pluginId: "acme/demo",
        approvedSourceId: "approved-source-a",
        digest: DIGEST,
        generation: 3,
      },
    ]);
  });

  it("drops inactive rows and produces an empty full-replacement projection", () => {
    const projected = projectApprovedPluginRuntime(
      input([contribution({ active: false })], { installations: [] }),
    );

    expect(projected.commands).toEqual([]);
    expect(projected.skills).toEqual([]);
    expect(projected.hooks).toEqual([]);
    expect(projected.resources).toEqual([]);
    expect(projected.agents).toEqual([]);
    expect(projected.mcp).toEqual([]);
    expect(projected.secretScopes).toEqual([]);
  });

  it("is deterministic and sorted independently of durable row order", () => {
    const first = projectApprovedPluginRuntime(input([agent(), contribution(), skill()]));
    const second = projectApprovedPluginRuntime(input([skill(), agent(), contribution()]));

    expect(first).toEqual(second);
    expect(first.commands[0]?.contributionId).toBe(
      "plugin:acme/demo/command:review",
    );
  });

  it("denies an active legacy row with no reviewed installation binding", () => {
    const legacy = contribution({
      installationId: undefined,
      approvedSourceId: undefined,
      digest: undefined,
      generation: undefined,
    });

    expectDenied(() => projectApprovedPluginRuntime(input([legacy])), "unreviewed");
  });

  it("denies a source whose review or approval state is not current", () => {
    const pendingSource = {
      ...source(),
      validationState: "pending",
    } as unknown as ApprovedSource;
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([contribution()], {
            installations: [installation({ approvedSource: pendingSource })],
          }),
        ),
      "approval_required",
    );
  });

  it("denies raw install channels at the projection input boundary", () => {
    for (const extra of [
      { source: { kind: "github", owner: "acme", repo: "other" } },
      { prompt: "install this" },
      { model: "install this" },
      { secrets: { TOKEN: "pasted-secret" } },
    ]) {
      expectDenied(
        () =>
          projectApprovedPluginRuntime({
            ...input(),
            ...extra,
          } as ApprovedRuntimeProjectionInput),
        "invalid_input",
      );
    }
  });

  it("denies a stale expected config generation", () => {
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution()], { expectedConfigGeneration: 6 })),
      "stale_generation",
    );
  });

  it("denies a contribution generation that differs from its approved installation", () => {
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution({ generation: 2 })])),
      "stale_generation",
    );
  });

  it("denies a stale full replacement instead of reusing old secret scopes", () => {
    const previous = projectApprovedPluginRuntime(input());

    expectDenied(
      () =>
        replaceApprovedPluginRuntimeProjection(
          previous,
          input([contribution({ active: false })], {
            configGeneration: 7,
            expectedConfigGeneration: 7,
            installations: [],
          }),
        ),
      "stale_generation",
    );
  });

  it("denies cross-user contribution and source bleed", () => {
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution({ userId: "user-b" })])),
      "owner_mismatch",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([contribution()], {
            installations: [installation({ approvedSource: source({ userId: "user-b" }) })],
          }),
        ),
      "owner_mismatch",
    );
  });

  it("reaches the previous-snapshot owner guard without mixing eviction scopes", () => {
    const previousA = projectApprovedPluginRuntime(validInputForUser("user-a"));
    const validB = validInputForUser("user-b", 8);

    // validB passes the complete projection, so this denial can only be the
    // previous.userId !== input.userId guard in the replacement function.
    expectDenied(
      () => replaceApprovedPluginRuntimeProjection(previousA, validB),
      "owner_mismatch",
    );
    expect(previousA.secretScopes).toHaveLength(1);
    expect(previousA.secretScopes.every((scope) => scope.userId === "user-a")).toBe(true);
    expect(JSON.stringify(previousA)).not.toContain('"userId":"user-b"');

    const oldOwnerRemoval = replaceApprovedPluginRuntimeProjection(
      previousA,
      input([contribution({ active: false })], {
        configGeneration: 8,
        expectedConfigGeneration: 8,
        installations: [],
      }),
    );
    const projectedB = projectApprovedPluginRuntime(validB);
    expect(oldOwnerRemoval.requiredSecretInvalidations).toEqual(previousA.secretScopes);
    expect(
      oldOwnerRemoval.requiredSecretInvalidations.every(
        (scope) => scope.userId === "user-a",
      ),
    ).toBe(true);
    expect(projectedB.secretScopes.every((scope) => scope.userId === "user-b")).toBe(true);
    expect(projectedB.secretScopes).not.toEqual(
      oldOwnerRemoval.requiredSecretInvalidations,
    );
    expect(JSON.stringify(projectedB)).not.toContain('"userId":"user-a"');
  });

  it("denies installation, source, digest, and plugin substitution", () => {
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution({ installationId: "other" })])),
      "unreviewed",
    );
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution({ approvedSourceId: "other" })])),
      "source_mismatch",
    );
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution({ digest: "sha256:changed" })])),
      "digest_mismatch",
    );
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution({ pluginId: "acme/other" })])),
      "source_mismatch",
    );
  });

  it("denies .dsh and automatic hook authority", () => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([contribution({ rootPath: "/workspace/.dsh" })], {
            installations: [installation({ contentRoot: "/workspace/.dsh" })],
          }),
        ),
      "forbidden_workspace_authority",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            hook({
              data: {
                type: "command",
                command: "node approved-hook.js",
                canBlock: true,
                ordinal: 0,
                auto: true,
              },
            }),
          ]),
        ),
      "unapproved_field",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([contribution({ data: { file: ".dsh/commands/review.md" } })]),
        ),
      "forbidden_workspace_authority",
    );
  });

  it.each([
    ["source", { source: { kind: "github", owner: "acme", repo: "other" } }],
    ["prompt", { prompt: "install and run this plugin" }],
    ["model", { model: "install acme/other" }],
    ["shell", { shell: "npx acme-other" }],
    ["secrets", { secrets: { TOKEN: "pasted-secret" } }],
  ])("denies arbitrary %s installation fields", (_label, extra) => {
    const forged = { ...contribution(), ...extra } as ApprovedContribution;
    expectDenied(() => projectApprovedPluginRuntime(input([forged])), "unapproved_field");
  });

  it("denies prompt/model/tool policy smuggled into file contributions", () => {
    for (const row of [
      skill({ data: { file: "skills/review/SKILL.md", prompt: "new system prompt" } }),
      agent({ data: { file: "agents/helper.md", model: "arbitrary-model" } }),
      agent({ data: { file: "agents/helper.md", tools: ["*"] } }),
      contribution({ data: { file: "commands/review.md", install: "npm package" } }),
    ]) {
      expectDenied(() => projectApprovedPluginRuntime(input([row])), "unapproved_field");
    }
  });

  it("denies capabilities not covered by both the source approval and grant", () => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([contribution()], {
            installations: [
              installation({
                approvedSource: source({ approvedCapabilities: ["hooksObserve"] }),
              }),
            ],
          }),
        ),
      "capability_mismatch",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([hook()], {
            installations: [installation({ grant: grant({ capabilities: ["hooksObserve"] }) })],
          }),
        ),
      "capability_mismatch",
    );
    expectDenied(
      () => projectApprovedPluginRuntime(input([remoteMcp()], {
        installations: [installation({ grant: grant({ capabilities: ["mcpRegister"] }) })],
      })),
      "capability_mismatch",
    );
  });

  it("denies undeclared MCP credential names and pasted secret side channels", () => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([stdioMcp()], {
            installations: [installation({ grant: grant({ envNames: ["API_TOKEN"] }) })],
          }),
        ),
      "secret_mismatch",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            stdioMcp({
              data: {
                imported: {
                  name: "local",
                  transport: "stdio",
                  command: "node",
                },
                secrets: { TOKEN: "pasted-secret" },
              },
            }),
          ]),
        ),
      "unapproved_field",
    );
  });

  it.each(["command", "args"] as const)(
    "denies an undeclared generic credential reference in emitted MCP %s",
    (field) => {
      const imported = field === "command"
        ? {
            name: "local",
            transport: "stdio",
            command: "node-${UNDECLARED_TOKEN:-/tmp/node}",
          }
        : {
            name: "local",
            transport: "stdio",
            command: "node",
            args: ["--token=${UNDECLARED_TOKEN}"],
          };
      expectDenied(
        () =>
          projectApprovedPluginRuntime(
            input([stdioMcp({ data: { imported } })], {
              installations: [
                installation({
                  grant: grant({
                    capabilities: ["mcpRegister", "processSpawn"],
                    envNames: [],
                  }),
                }),
              ],
            }),
          ),
        "capability_mismatch",
      );
    },
  );

  it.each([
    ["env generic", { env: { API_TOKEN: "${UNDECLARED_TOKEN}" } }, ["API_TOKEN"]],
    [
      "env user-config",
      { env: { API_TOKEN: "${user_config.api_key}" } },
      ["API_TOKEN"],
    ],
    [
      "header generic",
      { headers: { Authorization: "Bearer ${UNDECLARED_TOKEN}" } },
      ["Authorization"],
    ],
    [
      "header user-config",
      { headers: { Authorization: "Bearer ${user_config.api_key}" } },
      ["Authorization"],
    ],
  ] as const)(
    "denies an undeclared reference in an MCP %s value before stripping it",
    (_label, values, declaredNames) => {
      expectDenied(
        () =>
          projectApprovedPluginRuntime(
            input([
              stdioMcp({
                data: {
                  imported: {
                    name: "local",
                    transport: "stdio",
                    command: "node",
                    ...values,
                  },
                },
              }),
            ], {
              installations: [
                installation({
                  grant: grant({ envNames: [...declaredNames] }),
                }),
              ],
            }),
          ),
        "secret_mismatch",
      );
    },
  );

  it("denies undeclared OAuth credential references", () => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            remoteMcp({
              data: {
                imported: {
                  name: "remote",
                  transport: "http",
                  url: "https://mcp.example.test/endpoint",
                  oauth: { clientId: "${OAUTH_UNDECLARED}" },
                },
              },
            }),
          ]),
        ),
      "secret_mismatch",
    );
  });

  it("allows only declared MCP references while still dropping all env/header values", () => {
    const projected = projectApprovedPluginRuntime(
      input([
        stdioMcp({
          data: {
            imported: {
              name: "local",
              transport: "stdio",
              command: "node",
              args: ["--token=${API_TOKEN}"],
              env: { API_TOKEN: "${user_config.api_key}" },
              headers: { Authorization: "Bearer ${Authorization}" },
            },
          },
        }),
      ], {
        installations: [
          installation({
            grant: grant({
              envNames: ["API_TOKEN", "Authorization", "api_key"],
            }),
          }),
        ],
      }),
    );

    expect(projected.mcp[0]?.args).toEqual(["--token=${API_TOKEN}"]);
    expect(JSON.stringify(projected)).not.toContain("user_config.api_key");
    expect(projected.mcp[0]).not.toHaveProperty("env");
    expect(projected.mcp[0]).not.toHaveProperty("headers");
  });

  it("never emits MCP env/header values or extra persisted secret fields", () => {
    const withSecrets = {
      ...stdioMcp(),
      configSealed: { ciphertext: "pasted-secret" },
    } as ApprovedContribution;

    // The unknown top-level field is denied without echoing its value.
    try {
      projectApprovedPluginRuntime(input([withSecrets]));
      throw new Error("expected denial");
    } catch (error) {
      expect(error).toBeInstanceOf(ApprovedPluginRuntimeProjectionError);
      expect(JSON.stringify(error)).not.toContain("pasted-secret");
      expect((error as Error).message).not.toContain("pasted-secret");
    }

    const projected = projectApprovedPluginRuntime(input([stdioMcp()]));
    expect(JSON.stringify(projected)).not.toContain("pasted-secret");
    expect(projected.mcp[0]).not.toHaveProperty("env");
    expect(projected.mcp[0]).not.toHaveProperty("headers");
  });

  it("denies path escape and undeclared retained user-config references", () => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([contribution({ data: { file: "../workspace/secret.md" } })]),
        ),
      "invalid_contribution",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            hook({
              data: {
                type: "command",
                command: "node hook.js --token=${user_config.api_key}",
                canBlock: true,
                ordinal: 0,
              },
            }),
          ]),
        ),
      "secret_mismatch",
    );
  });

  it("confines rootPath to the installation's independent canonical contentRoot", () => {
    for (const rootPath of [
      "/workspace",
      "/jail/plugins/acme/demo/../../workspace",
      "/jail/plugins/acme/demo/1.0.0/../1.0.0",
      "/jail/plugins/acme/demo/symlink-alias",
    ]) {
      expectDenied(
        () => projectApprovedPluginRuntime(input([contribution({ rootPath })])),
        "source_mismatch",
      );
    }

    for (const contentRoot of [
      "/workspace",
      "/jail/plugins/acme/demo/../../workspace",
      "/jail/plugins/acme/demo/1.0.0/",
    ]) {
      expectDenied(
        () =>
          projectApprovedPluginRuntime(
            input([contribution({ rootPath: contentRoot })], {
              installations: [installation({ contentRoot })],
            }),
          ),
        "invalid_input",
      );
    }
  });

  it.each([
    { command: ".dsh/server" },
    { command: "node", args: ["/workspace/.dsh/server.js"] },
    { command: "node", cwd: ".dsh" },
    {
      command: "env",
      args: ["bash", "-lc", "cd .dsh;node server.js"],
    },
    {
      command: "env",
      args: ["bash", "-lc", "cd plugins/%2e%64%73%68 && node server.js"],
    },
    {
      command: "node",
      cwd: "packages/%252e%2564%2573%2568",
    },
  ])("denies direct and nested .dsh authority in MCP stdio metadata", (paths) => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            stdioMcp({
              data: {
                imported: {
                  name: "local",
                  transport: "stdio",
                  ...paths,
                },
              },
            }),
          ]),
        ),
      "forbidden_workspace_authority",
    );
  });

  it.each([
    {
      command: "env",
      args: ["bash", "-lc", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["bash", "-lc", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["bash", "-lc", "cd .d\u2019\u2019sh;node server.js"],
    },
    { command: "bash", args: ["-lc", "node .d''sh/server"] },
    { command: "sh", args: ["-c", "node .d\\sh/server"] },
  ])("rejects shell quote/escape-split wrapped stdio authority", (paths) => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            stdioMcp({
              data: {
                imported: {
                  name: "local",
                  transport: "stdio",
                  ...paths,
                },
              },
            }),
          ]),
        ),
      "forbidden_workspace_authority",
    );
  });

  it.each([
    {
      command: "env",
      args: ["bash", "-o", "posix", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["bash", "-O", "extglob", "-c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["-", "bash", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["-S", "bash -c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["--split-string", "bash -c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["--split-string=bash -c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["-a", "ignored", "bash", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["--argv0=ignored", "bash", "-c", "cd .d\\sh;node server.js"],
    },
  ])("denies shell operand and Coreutils env inline-selection bypasses", (paths) => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            stdioMcp({
              data: {
                imported: {
                  name: "local",
                  transport: "stdio",
                  ...paths,
                },
              },
            }),
          ]),
        ),
      "forbidden_workspace_authority",
    );
  });

  it.each([
    {
      command: "env",
      args: ["x-y=z", "bash", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["9name=value", "bash", "-c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["env", "-S", "bash -c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["env", "-", "bash", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["env", "-a", "ignored", "bash", "-c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["-a", "ignored", "env", "bash", "-o", "posix", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["env", "env", "-", "bash", "-c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["bash", "+O", "extglob", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "--emulate", "sh", "-c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "-o", "shwordsplit", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "+o", "shwordsplit", "-c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "-xo", "shwordsplit", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "-9c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "-9c", "cd .d\\sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "-x9c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["bash", "--unknown-option", "operand", "-c", "cd .d''sh;node server.js"],
    },
    {
      command: "env",
      args: ["zsh", "--unknown-option", "operand", "-c", "cd .d\\sh;node server.js"],
    },
  ])("denies assignment, nested-env, and shell-option scanner bypasses", (paths) => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            stdioMcp({
              data: {
                imported: {
                  name: "local",
                  transport: "stdio",
                  ...paths,
                },
              },
            }),
          ]),
        ),
      "forbidden_workspace_authority",
    );
  });

  it.each([
    [
      "ordinary assignments",
      [
        "NODE_ENV=production",
        "FEATURE=a|b",
        "HELPER=helpers/bash",
        "x-y=z",
        "9name=value",
        "/usr/bin/node",
        "--stdio",
        '{"pattern":"a|b","enabled":true}',
      ],
    ],
    [
      "ignore-environment dash and assignment",
      ["-", "NODE_ENV=production", "/usr/bin/node", "--stdio"],
    ],
    [
      "unset plus assignment",
      ["-u", "HOME", "NODE_ENV=production", "/usr/bin/node", "--stdio"],
    ],
    ["argv0", ["-a", "ignored", "/usr/bin/node", "--stdio"]],
    ["attached argv0", ["--argv0=ignored", "/usr/bin/node", "--stdio"]],
    [
      "double-dash selection",
      ["--", "/usr/bin/node", "--stdio", "x-y=z"],
    ],
    [
      "dash and double-dash selection",
      ["-", "--", "/usr/bin/node", "--stdio"],
    ],
  ] as const)("retains safe env %s without shell reclassification", (_label, args) => {
    const projected = projectApprovedPluginRuntime(
      input([
        stdioMcp({
          data: {
            imported: {
              name: "local",
              transport: "stdio",
              command: "/usr/bin/env",
              args: [...args],
              cwd: "servers/sh",
            },
          },
        }),
      ]),
    );

    expect(projected.mcp[0]?.command).toBe("/usr/bin/env");
    expect(projected.mcp[0]?.args).toEqual([...args]);
    expect(projected.mcp[0]?.cwd).toBe("servers/sh");
  });

  it("does not reinterpret opaque argv after a selected script filename", () => {
    const args = ["bash", "script.sh", "-c", "a|b", '{"json":true}'];
    const projected = projectApprovedPluginRuntime(
      input([
        stdioMcp({
          data: {
            imported: {
              name: "local",
              transport: "stdio",
              command: "env",
              args,
            },
          },
        }),
      ]),
    );

    expect(projected.mcp[0]?.args).toEqual(args);
  });

  it("retains direct argv and cwd data without treating shell-like text as a wrapper", () => {
    const args = [
      "--stdio",
      "sh",
      "zsh",
      "shwordsplit",
      "-9c",
      "helpers/bash",
      "-S",
      "bash -c",
      "-o",
      "posix",
      "a|b",
      '{"pattern":"a|b","enabled":true}',
    ];
    const projected = projectApprovedPluginRuntime(
      input([
        stdioMcp({
          data: {
            imported: {
              name: "local",
              transport: "stdio",
              command: "/usr/bin/node",
              args,
              cwd: "servers/sh",
            },
          },
        }),
      ]),
    );

    expect(projected.mcp[0]).toMatchObject({
      command: "/usr/bin/node",
      args,
      cwd: "servers/sh",
    });
    expect(projected.mcp[0]?.args).toEqual(args);
  });

  it("rejects a self-consistent resource name containing real parent segments", () => {
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            resource({
              canonicalId: "plugin:acme/demo/resource:x/../outside",
              name: "x/../outside",
            }),
          ]),
        ),
      "invalid_contribution",
    );
  });

  it("denies malformed canonical IDs and unsupported setting contributions", () => {
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution({ canonicalId: "plugin:other" })])),
      "invalid_contribution",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            contribution({
              canonicalId: "plugin:acme/demo/setting:token",
              kind: "setting",
              name: "token",
              data: { value: "pasted-secret" },
            }),
          ]),
        ),
      "unsupported_contribution",
    );
  });

  it("denies duplicate canonical IDs instead of choosing attacker-controlled order", () => {
    expectDenied(
      () => projectApprovedPluginRuntime(input([contribution(), contribution()])),
      "duplicate_contribution",
    );
  });

  it("bounds contribution counts, paths, hook commands, and MCP metadata", () => {
    const rows = Array.from(
      { length: APPROVED_RUNTIME_LIMITS.maxContributions + 1 },
      (_, index) => contribution({ canonicalId: `${contribution().canonicalId}:${index}` }),
    );
    expectDenied(() => projectApprovedPluginRuntime(input(rows)), "limit_exceeded");
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([contribution({ data: { file: `commands/${"x".repeat(2000)}.md` } })]),
        ),
      "limit_exceeded",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            hook({
              data: {
                type: "command",
                command: "x".repeat(APPROVED_RUNTIME_LIMITS.maxHookCommandLength + 1),
                canBlock: true,
                ordinal: 0,
              },
            }),
          ]),
        ),
      "limit_exceeded",
    );
    expectDenied(
      () =>
        projectApprovedPluginRuntime(
          input([
            stdioMcp({
              data: {
                imported: {
                  name: "local",
                  transport: "stdio",
                  command: "node",
                  args: Array.from(
                    { length: APPROVED_RUNTIME_LIMITS.maxMcpArguments + 1 },
                    () => "arg",
                  ),
                },
              },
            }),
          ]),
        ),
      "limit_exceeded",
    );
  });

  it("full replacement removes old contributions and requires invalidation of every old secret scope", () => {
    const previous = projectApprovedPluginRuntime(input([contribution(), stdioMcp()]));
    const replaced = replaceApprovedPluginRuntimeProjection(
      previous,
      input([skill()], {
        configGeneration: 8,
        expectedConfigGeneration: 8,
        installations: [
          installation({
            installationId: "installation-b",
            generation: 4,
            approvedSource: source({
              approvedSourceId: "approved-source-b",
              digest: "sha256:new-content",
            }),
            grant: grant({ manifestDigest: "sha256:new-content" }),
          }),
        ],
        contributions: [
          skill({
            installationId: "installation-b",
            approvedSourceId: "approved-source-b",
            digest: "sha256:new-content",
            generation: 4,
          }),
        ],
      }),
    );

    expect(replaced.projection.commands).toEqual([]);
    expect(replaced.projection.mcp).toEqual([]);
    expect(replaced.projection.skills).toHaveLength(1);
    expect(replaced.projection.configGeneration).toBe(8);
    expect(replaced.requiredSecretInvalidations).toEqual(previous.secretScopes);
    expect(replaced.requiredSecretInvalidations[0]).not.toEqual(
      replaced.projection.secretScopes[0],
    );
  });

  it("uninstall removes the old projection and invalidates secrets without touching another user's snapshot", () => {
    const forA = projectApprovedPluginRuntime(input([contribution(), stdioMcp()]));
    const forB = projectApprovedPluginRuntime(validInputForUser("user-b"));
    const beforeB = JSON.stringify(forB);

    const uninstalled = replaceApprovedPluginRuntimeProjection(
      forA,
      input([contribution({ active: false })], {
        configGeneration: 8,
        expectedConfigGeneration: 8,
        installations: [],
      }),
    );

    expect(uninstalled.projection.commands).toEqual([]);
    expect(uninstalled.projection.mcp).toEqual([]);
    expect(uninstalled.projection.secretScopes).toEqual([]);
    expect(uninstalled.requiredSecretInvalidations).toEqual(forA.secretScopes);
    expect(JSON.stringify(forB)).toBe(beforeB);
  });
});
