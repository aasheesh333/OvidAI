// Task 13 — capability grants (Dart plugin_permissions parity, cloud-reduced).
// Grants are NEVER auto-approved: every non-empty capability delta pauses
// activation until the user approves the update (spec §5.1). Digest binding
// (which manifest the grant was recorded for) is the installer's duty
// (Task 14 loads the stored grant by digest); these functions are the pure
// capability math.

import { describe, expect, it } from "vitest";
import {
  CAPABILITY_EXPLANATIONS,
  capabilityDelta,
  grantCovers,
  type PluginCapability,
  type PluginGrantInput,
} from "./grants.js";

const BASE_CAPS: PluginCapability[] = [
  "workspaceRead",
  "mcpRegister",
  "processSpawn",
  "environmentRead",
];

function grant(overrides: Partial<PluginGrantInput> = {}): PluginGrantInput {
  return {
    capabilities: BASE_CAPS,
    envNames: ["MCP_TOKEN"],
    manifestDigest: "sha256:abc",
    allowDependencyScripts: false,
    ...overrides,
  };
}

describe("capabilityDelta", () => {
  it("a null grant yields every requested capability (first approval)", () => {
    const delta = capabilityDelta(new Set(BASE_CAPS), null);
    expect([...delta].sort()).toEqual([...BASE_CAPS].sort());
  });

  it("an exact grant yields an empty delta", () => {
    const delta = capabilityDelta(new Set(BASE_CAPS), grant());
    expect(delta).toEqual([]);
  });

  it("an update adding a hook forces re-approval (non-empty delta)", () => {
    // The plugin grew a blocking command hook between versions.
    const updated = new Set<PluginCapability>([
      ...BASE_CAPS,
      "hooksObserve",
      "hooksBlock",
      "shellExecute",
    ]);
    const delta = capabilityDelta(updated, grant());
    expect(delta.sort()).toEqual(["hooksBlock", "hooksObserve", "shellExecute"]);
  });

  it("extra granted capabilities beyond the request are not a delta", () => {
    const extra = grant({ capabilities: [...BASE_CAPS, "networkConnect"] });
    expect(capabilityDelta(new Set(BASE_CAPS), extra)).toEqual([]);
  });
});

describe("grantCovers", () => {
  it("is the inverse of capabilityDelta (empty delta)", () => {
    expect(grantCovers(new Set(BASE_CAPS), grant())).toBe(true);
    expect(grantCovers(new Set(BASE_CAPS), null)).toBe(false);
    const updated = new Set<PluginCapability>([...BASE_CAPS, "shellExecute"]);
    expect(grantCovers(updated, grant())).toBe(false);
  });
});

describe("CAPABILITY_EXPLANATIONS", () => {
  it("carries one non-empty human line per capability in the vocabulary", () => {
    const vocabulary: PluginCapability[] = [
      "workspaceRead",
      "workspaceWrite",
      "shellExecute",
      "networkConnect",
      "processSpawn",
      "environmentRead",
      "mcpRegister",
      "hooksObserve",
      "hooksBlock",
    ];
    expect(Object.keys(CAPABILITY_EXPLANATIONS).sort()).toEqual(
      [...vocabulary].sort(),
    );
    for (const line of Object.values(CAPABILITY_EXPLANATIONS)) {
      expect(typeof line).toBe("string");
      expect(line.length).toBeGreaterThan(0);
    }
  });
});
