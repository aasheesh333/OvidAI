// Task 13 — contribution registry: the P3 seam. Hook EXECUTION is P3's
// engine; this registry is registration only. Canonical ids are
// version-independent (plugin:<id>/<kind>:<name>), so a reinstall/upgrade
// re-registers the same ids — register() must UPSERT idempotently and never
// throw, or atomic installs (Task 14) could not re-activate an upgraded
// plugin over its own prior registration.

import { describe, expect, it } from "vitest";
import {
  contributionsFromManifest,
  createContributionRegistry,
  type ContributionRecord,
} from "./registry.js";
import type { NormalizedPluginManifest } from "./manifest.js";

function rec(
  canonicalId: string,
  overrides: Partial<ContributionRecord> = {},
): ContributionRecord {
  // plugin:<publisher>/<name>/<kind>:<name>
  const parts = canonicalId.split(/[:/]/);
  const kind = parts[3] ?? "command";
  const name = parts[4] ?? "x";
  return {
    canonicalId,
    kind,
    pluginId: "acme/demo",
    name,
    rootPath: "/plugins/acme/demo",
    data: {},
    ...overrides,
  };
}

function manifestOf(
  overrides: Partial<NormalizedPluginManifest> = {},
): NormalizedPluginManifest {
  return {
    pluginId: "acme/demo",
    version: "1.0.0",
    format: "claudeCode",
    commands: [{ name: "foo", file: "commands/foo.md" }],
    skills: [{ name: "review", file: "skills/review/SKILL.md" }],
    agents: [{ name: "coder", file: "agents/coder.md" }],
    hooks: [
      {
        event: "PreToolUse",
        type: "command",
        command: "echo hi",
        canBlock: true,
        ordinal: 0,
      },
    ],
    mcpServers: [
      {
        name: "bar",
        imported: { name: "bar", transport: "stdio", command: "node" },
      },
    ],
    capabilities: [],
    envNames: [],
    warnings: [],
    rootPath: "/plugins/acme/demo/1.0.0",
    ...overrides,
  };
}

describe("createContributionRegistry", () => {
  it("registers, lists, gets and unregisters", () => {
    const r = createContributionRegistry();
    const a = rec("plugin:acme/demo/command:foo");
    const b = rec("plugin:other/pkg/command:foo", { pluginId: "other/pkg" });
    r.register([a, b]);

    expect(r.list()).toHaveLength(2);
    expect(r.get("plugin:acme/demo/command:foo")?.canonicalId).toBe(
      "plugin:acme/demo/command:foo",
    );
    expect(r.get("plugin:none/none")).toBeUndefined();

    expect(r.list({ kind: "command" })).toHaveLength(2);
    expect(r.list({ pluginId: "acme/demo" })).toHaveLength(1);
    expect(r.list({ pluginId: "acme/demo", kind: "command" })[0]?.name).toBe(
      "foo",
    );

    expect(r.unregisterPlugin("acme/demo")).toBe(1);
    expect(r.list()).toHaveLength(1);
    expect(r.list()[0]?.pluginId).toBe("other/pkg");
    expect(r.get("plugin:acme/demo/command:foo")).toBeUndefined();
  });

  it("re-registering an existing canonicalId upserts idempotently (reinstall pin)", () => {
    const r = createContributionRegistry();
    const id = "plugin:acme/demo/command:foo";
    r.register([rec(id, { data: { version: 1 } })]);
    expect(() =>
      r.register([rec(id, { data: { version: 2 } })]),
    ).not.toThrow();
    // The record is REPLACED, and the total count is unchanged.
    expect(r.list()).toHaveLength(1);
    expect(r.get(id)?.data).toEqual({ version: 2 });
  });

  it("a duplicate canonicalId within one register() call throws", () => {
    const r = createContributionRegistry();
    const id = "plugin:acme/demo/command:foo";
    expect(() => r.register([rec(id), rec(id)])).toThrow();
    // Atomic: nothing from the aborted call survives.
    expect(r.list()).toHaveLength(0);
  });

  it("unregisterPlugin removes only that plugin's records", () => {
    const r = createContributionRegistry();
    r.register([
      rec("plugin:acme/demo/command:foo", { pluginId: "acme/demo" }),
      rec("plugin:acme/demo/mcp:bar", {
        pluginId: "acme/demo",
        kind: "mcp",
        name: "bar",
      }),
      rec("plugin:other/pkg/command:foo", { pluginId: "other/pkg" }),
    ]);
    expect(r.unregisterPlugin("acme/demo")).toBe(2);
    expect(r.list().map((x) => x.canonicalId)).toEqual([
      "plugin:other/pkg/command:foo",
    ]);
    // A plugin with no records unregisters zero.
    expect(r.unregisterPlugin("acme/demo")).toBe(0);
  });
});

describe("contributionsFromManifest", () => {
  it("derives canonical ids per contribution kind", () => {
    const m = manifestOf();
    const recs = contributionsFromManifest(m);
    const ids = recs.map((x) => x.canonicalId);
    expect(ids).toContain("plugin:acme/demo/command:foo");
    expect(ids).toContain("plugin:acme/demo/skill:review");
    expect(ids).toContain("plugin:acme/demo/agent:coder");
    expect(ids).toContain("plugin:acme/demo/hook:PreToolUse:0");
    expect(ids).toContain("plugin:acme/demo/mcp:bar");
    for (const r of recs) {
      expect(r.pluginId).toBe("acme/demo");
      expect(r.rootPath).toBe("/plugins/acme/demo/1.0.0");
    }
    const hook = recs.find((x) => x.kind === "hook");
    expect(hook?.data).toEqual({
      type: "command",
      command: "echo hi",
      canBlock: true,
      ordinal: 0,
    });
    const mcp = recs.find((x) => x.kind === "mcp");
    expect(mcp?.data.imported).toMatchObject({ name: "bar", command: "node" });
  });

  it("produces registry-ready records: register → list round-trip", () => {
    const r = createContributionRegistry();
    const recs = contributionsFromManifest(manifestOf());
    r.register(recs);
    expect(r.list()).toHaveLength(recs.length);
    // Re-deriving from the same manifest (a reinstall of the same version)
    // re-registers the same canonical ids idempotently.
    r.register(contributionsFromManifest(manifestOf()));
    expect(r.list()).toHaveLength(recs.length);
    expect(r.unregisterPlugin("acme/demo")).toBe(recs.length);
  });
});
