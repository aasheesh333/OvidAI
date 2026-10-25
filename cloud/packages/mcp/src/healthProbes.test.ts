// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { describe, expect, it } from "vitest";

import { FETCH_OPERATIONS } from "./native/fetch.js";
import { GITHUB_READ_OPERATIONS } from "./native/github.js";
import { DEV_WORK_CONTRACT_DEFINITIONS } from "./rest/descriptors/devWork.js";
import { healthProbeArgs } from "./healthProbes.js";

function operation(providerId: string, operationId: string) {
  if (providerId === "fetch") {
    const selected = FETCH_OPERATIONS.find((candidate) => candidate.name === operationId);
    if (selected === undefined) throw new Error("missing Fetch fixture");
    return selected;
  }
  if (providerId === "github") {
    const selected = GITHUB_READ_OPERATIONS.find((candidate) => candidate.name === operationId);
    if (selected === undefined) throw new Error("missing GitHub fixture");
    return selected;
  }
  const selected = DEV_WORK_CONTRACT_DEFINITIONS.find((definition) => definition.providerId === providerId)
    ?.operations.find((candidate) => candidate.name === operationId);
  if (selected === undefined) throw new Error("missing provider fixture");
  return selected;
}

describe("provider-family health probe allowlist", () => {
  it.each([
    ["github", "get_user", {}],
    ["cloudflare", "list_zones", { page: 1, per_page: 5 }],
    ["vercel", "list_projects", { limit: 1 }],
  ] as const)("builds the bounded %s probe from the real typed operation", (providerId, operationId, expected) => {
    expect(healthProbeArgs({
      providerId,
      operation: operation(providerId, operationId),
      config: null,
    })).toEqual(expected);
  });

  it("does not fabricate repository/resource coordinates for unreviewed operations", () => {
    expect(healthProbeArgs({
      providerId: "github",
      operation: operation("github", "list_issues"),
      config: { owner: "must-not-be-used-without-review", repo: "unknown" },
    })).toBeNull();
    expect(healthProbeArgs({
      providerId: "unknown-provider",
      operation: operation("github", "get_user"),
      config: null,
    })).toBeNull();
  });

  it("accepts only bounded connection-owned public HTTPS fetch inputs", () => {
    expect(healthProbeArgs({
      providerId: "fetch",
      operation: operation("fetch", "fetch"),
      config: { url: "http://127.0.0.1/private" },
    })).toBeNull();
    expect(healthProbeArgs({
      providerId: "fetch",
      operation: operation("fetch", "fetch"),
      config: { url: "https://user:password@example.test/private" },
    })).toBeNull();
    expect(healthProbeArgs({
      providerId: "fetch",
      operation: operation("fetch", "fetch"),
      config: { url: "https://example.test/public" },
    })).toEqual({ url: "https://example.test/public", max_length: 1_000 });
  });
});
