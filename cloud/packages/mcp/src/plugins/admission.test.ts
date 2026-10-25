import { describe, expect, it } from "vitest";

import {
  admitApprovedSource,
  ApprovedSourceAdmissionError,
  type ApprovedSource,
  type ApprovedSourceAdmissionRecord,
  type ApprovedSourceInspection,
  type ApprovedSourceJob,
} from "./admission.js";

const registered: ApprovedSource = {
  approvedSourceId: "approved-source-1",
  userId: "user-1",
  canonicalSource: "github:acme/demo",
  resolvedRevision: "0123456789abcdef",
  digest: "sha256:approved-content",
  provenance: {
    kind: "github",
    githubRepo: "acme/demo",
    revision: "0123456789abcdef",
  },
  validationState: "validated",
  approvalState: "approved",
  approvedCapabilities: ["workspaceRead", "mcpRegister"],
};

const job: ApprovedSourceJob = {
  approvedSourceId: "approved-source-1",
  expectedDigest: "sha256:approved-content",
  installationId: "installation-1",
  userId: "user-1",
  mode: "install",
};

const inspected: ApprovedSourceInspection = {
  canonicalSource: "github:acme/demo",
  resolvedRevision: "0123456789abcdef",
  digest: "sha256:approved-content",
  capabilities: ["workspaceRead", "mcpRegister"],
};

function request(
  overrides: Partial<ApprovedSourceAdmissionRecord> = {},
): ApprovedSourceAdmissionRecord {
  return {
    job: { ...job },
    registered: {
      ...registered,
      provenance: { ...registered.provenance },
      approvedCapabilities: [...registered.approvedCapabilities],
    },
    inspected: { ...inspected, capabilities: [...inspected.capabilities] },
    ...overrides,
  };
}

describe("admitApprovedSource", () => {
  it("admits only the exact approved source/revision/digest/capability binding", async () => {
    // Break caught: admitting a different inspected artifact or capability set.
    await expect(admitApprovedSource(request())).resolves.toEqual({
      installationId: "installation-1",
      mode: "install",
      approvedSource: registered,
    });
  });

  it("treats capability order as irrelevant but never ignores a capability delta", async () => {
    // Break caught: array-order comparison rejecting the same approved set, or
    // subset comparison admitting an added privilege.
    const reordered = request({
      inspected: { ...inspected, capabilities: ["mcpRegister", "workspaceRead"] },
    });
    await expect(admitApprovedSource(reordered)).resolves.toBeDefined();

    const expanded = request({
      inspected: {
        ...inspected,
        capabilities: [...inspected.capabilities, "shellExecute"],
      },
    });
    await expect(admitApprovedSource(expanded)).rejects.toMatchObject({
      name: "ApprovedSourceAdmissionError",
      code: "capability_mismatch",
    });
  });

  it.each([
    ["GitHub", { source: { kind: "github", owner: "acme", repo: "demo" } }],
    ["npm", { source: { kind: "npm", package: "@acme/demo" } }],
    ["ZIP", { source: { kind: "zip", url: "https://example.test/demo.zip" } }],
    ["paste", { source: { kind: "paste", label: "demo", config: "pasted-secret" } }],
    ["custom MCP", { customMcp: { url: "https://mcp.example.test" } }],
    ["model", { model: "install acme/demo" }],
    ["prompt", { prompt: "install acme/demo" }],
    ["shell", { shell: "npx @acme/demo" }],
    ["secrets", { secrets: { TOKEN: "pasted-secret" } }],
  ])("denies raw %s job input instead of staging it", async (_label, raw) => {
    // Break caught: accepting extra job fields, which would let a producer
    // smuggle an unreviewed resolver input or secret beside an approved ref.
    const rawJob = { ...job, ...raw } as ApprovedSourceJob;
    const attempt = admitApprovedSource(request({ job: rawJob }));

    await expect(attempt).rejects.toBeInstanceOf(ApprovedSourceAdmissionError);
    await expect(attempt).rejects.toMatchObject({ code: "invalid_job" });
    await expect(attempt).rejects.not.toHaveProperty("approvedSource");
  });

  it("denies an unregistered source", async () => {
    // Break caught: constructing an approval from caller-supplied metadata
    // when no registered approved-source row exists.
    await expect(
      admitApprovedSource(request({ registered: null })),
    ).rejects.toMatchObject({ code: "unregistered_source" });
  });

  it.each([
    ["validationState", "pending"],
    ["approvalState", "revoked"],
  ])("denies a registered row whose %s is not approved", async (field, value) => {
    // Break caught: checking only source identity and ignoring review state.
    const unreviewed = {
      ...registered,
      [field]: value,
    } as ApprovedSource;
    await expect(
      admitApprovedSource(request({ registered: unreviewed })),
    ).rejects.toMatchObject({ code: "approval_required" });
  });

  it("denies a registered row carrying pasted top-level fields", async () => {
    // Break caught: projecting arbitrary row properties into the staged value.
    const withSecrets = {
      ...registered,
      pastedConfig: "pasted-secret",
      secrets: { TOKEN: "pasted-secret" },
    } as ApprovedSource;
    const attempt = admitApprovedSource(request({ registered: withSecrets }));

    await expect(attempt).rejects.toMatchObject({
      code: "invalid_registered_source",
    });
    await expect(attempt).rejects.not.toHaveProperty("pastedConfig");
  });

  it("denies provenance carrying pasted config or secrets", async () => {
    // Break caught: treating provenance as an arbitrary bag and returning
    // nested pasted material in an otherwise exact ApprovedSource shape.
    const withSecrets = {
      ...registered,
      provenance: {
        ...registered.provenance,
        config: "pasted-secret",
        secrets: { TOKEN: "pasted-secret" },
      },
    };
    await expect(
      admitApprovedSource(request({ registered: withSecrets })),
    ).rejects.toMatchObject({ code: "invalid_registered_source" });
  });

  it("denies a job digest that differs from the approved digest", async () => {
    // Break caught: trusting expectedDigest without matching the persisted row.
    await expect(
      admitApprovedSource(
        request({ job: { ...job, expectedDigest: "sha256:changed" } }),
      ),
    ).rejects.toMatchObject({ code: "digest_mismatch" });
  });

  it.each([
    ["canonicalSource", "github:acme/other", "source_mismatch"],
    ["resolvedRevision", "fedcba9876543210", "source_mismatch"],
    ["digest", "sha256:changed-content", "digest_mismatch"],
  ] as const)("a changed inspected %s invalidates approval", async (field, value, code) => {
    // Break caught: treating approval as attaching to a mutable source label
    // rather than the exact revision and content digest.
    await expect(
      admitApprovedSource(
        request({ inspected: { ...inspected, [field]: value } }),
      ),
    ).rejects.toMatchObject({ code });
  });

  it("denies a capability removal as well as an addition", async () => {
    // Break caught: grantCovers-style subset logic at the source-admission
    // boundary; Task 12 requires the exact user-approved set.
    await expect(
      admitApprovedSource(
        request({
          inspected: { ...inspected, capabilities: ["workspaceRead"] },
        }),
      ),
    ).rejects.toMatchObject({ code: "capability_mismatch" });
  });

  it("denies cross-user and cross-source identity substitution", async () => {
    // Break caught: looking up/checking only approvedSourceId and allowing a
    // different owner's approved row to satisfy this job.
    await expect(
      admitApprovedSource(request({ job: { ...job, userId: "user-2" } })),
    ).rejects.toMatchObject({ code: "owner_mismatch" });

    await expect(
      admitApprovedSource(
        request({ job: { ...job, approvedSourceId: "approved-source-2" } }),
      ),
    ).rejects.toMatchObject({ code: "source_mismatch" });
  });
});
