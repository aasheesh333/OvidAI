import { describe, expect, it } from "vitest";

import {
  ContributionActivationError,
  createApprovedContributionReader,
  projectApprovedContribution,
  runApprovedContributionTransaction,
  type ApprovedContribution,
  type ApprovedContributionStore,
  type ContributionRollbackOutcome,
  type ContributionTransactionContext,
  type ContributionTransactionPort,
  type PersistedContribution,
  type StagedApprovedContributions,
} from "./contributions.js";

function approved(
  overrides: Partial<ApprovedContribution> = {},
): ApprovedContribution {
  return {
    canonicalId: "plugin:acme/demo/command:review",
    kind: "command",
    pluginId: "acme/demo",
    name: "review",
    rootPath: "/plugins/acme/demo/1.0.0",
    data: { file: "commands/review.md", description: "Review the workspace" },
    userId: "user-a",
    installationId: "installation-a",
    approvedSourceId: "approved-source-a",
    digest: "sha256:content-a",
    generation: 7,
    active: true,
    ...overrides,
  };
}

function unreviewed(userId = "user-a"): PersistedContribution {
  return {
    canonicalId: "plugin:acme/demo/command:review",
    kind: "command",
    pluginId: "acme/demo",
    name: "review",
    rootPath: "/plugins/acme/demo/legacy",
    data: { file: "commands/review.md" },
    userId,
    active: true,
  };
}

class MemoryContributionStore implements ApprovedContributionStore {
  constructor(readonly rows: PersistedContribution[]) {}

  async listByUser(userId: string): Promise<readonly PersistedContribution[]> {
    return this.rows.filter((row) => row.userId === userId);
  }
}

const completeRollback = (): ContributionRollbackOutcome => ({
  previousVersionPreserved: true,
  stagingRemoved: true,
  spawnedProcessesStopped: true,
  newConnectionsRemoved: true,
  newSealedConfigRemoved: true,
  newRegistrationsRemoved: true,
});

const transactionContext: ContributionTransactionContext = {
  userId: "user-a",
  installationId: "installation-a",
  approvedSourceId: "approved-source-a",
  digest: "sha256:content-a",
  generation: 7,
};

function staged(): StagedApprovedContributions {
  return {
    ...transactionContext,
    contributions: [approved({ active: false })],
  };
}

describe("persisted contribution projection", () => {
  it("projects the approved persisted shape and drops pasted top-level fields", () => {
    // Break caught: spreading a database/runtime row into the DTO and thereby
    // retaining pasted config or secret material beside the approved fields.
    const row = {
      ...approved(),
      pastedConfig: "pasted-secret",
      configSealed: { ciphertext: "pasted-secret" },
      secrets: { TOKEN: "pasted-secret" },
    } as ApprovedContribution;

    const projected = projectApprovedContribution(row);
    expect(projected).toEqual(approved());
    expect(JSON.stringify(projected)).not.toContain("pasted-secret");
    expect(Object.keys(projected ?? {}).sort()).toEqual(
      Object.keys(approved()).sort(),
    );
  });

  it("keeps MCP connection metadata but never persists env/header values", () => {
    // Break caught: retaining ContributionRecord.data.imported verbatim from
    // a pasted MCP config, including its plaintext credential maps.
    const row = approved({
      canonicalId: "plugin:acme/demo/mcp:remote",
      kind: "mcp",
      name: "remote",
      data: {
        imported: {
          name: "remote",
          transport: "stdio",
          command: "node",
          args: ["server.js"],
          env: { API_TOKEN: "pasted-secret" },
          headers: { Authorization: "Bearer pasted-secret" },
        },
        config: "pasted-secret",
      },
    });

    const projected = projectApprovedContribution(row);
    expect(projected?.data).toEqual({
      imported: {
        name: "remote",
        transport: "stdio",
        command: "node",
        args: ["server.js"],
      },
      envNames: ["API_TOKEN"],
      headerNames: ["Authorization"],
    });
    expect(JSON.stringify(projected)).not.toContain("pasted-secret");
  });

  it("does not project an existing unreviewed row as approved", () => {
    // Break caught: defaulting absent approval metadata or treating the old
    // active flag as proof that the exact source/digest was reviewed.
    expect(projectApprovedContribution(unreviewed())).toBeNull();
  });
});

describe("authoritative per-user contribution reader and registry cache", () => {
  it("keeps unreviewed rows readable but never activatable", async () => {
    // Break caught: hiding legacy rows from reads or allowing their legacy
    // active=true flag onto the runtime path.
    const reader = createApprovedContributionReader({
      store: new MemoryContributionStore([unreviewed()]),
    });

    await expect(reader.list("user-a")).resolves.toEqual([unreviewed()]);
    expect(reader.cached("user-a")).toEqual([]);
    await expect(
      reader.requireActive({
        userId: "user-a",
        canonicalId: unreviewed().canonicalId,
        installationId: "installation-a",
        expectedDigest: "sha256:content-a",
        expectedGeneration: 7,
      }),
    ).rejects.toMatchObject({ code: "unreviewed" });
  });

  it("isolates identical canonical ids for two users in both reads and cache", async () => {
    // Break caught: keying authoritative records or the shared registry cache
    // by canonicalId without userId.
    const store = new MemoryContributionStore([
      approved(),
      approved({
        userId: "user-b",
        installationId: "installation-b",
        approvedSourceId: "approved-source-b",
        digest: "sha256:content-b",
        rootPath: "/user-b/acme/demo",
      }),
    ]);
    const reader = createApprovedContributionReader({ store });

    const forA = await reader.requireActive({
      userId: "user-a",
      canonicalId: approved().canonicalId,
      installationId: "installation-a",
      expectedDigest: "sha256:content-a",
      expectedGeneration: 7,
    });
    const forB = await reader.requireActive({
      userId: "user-b",
      canonicalId: approved().canonicalId,
      installationId: "installation-b",
      expectedDigest: "sha256:content-b",
      expectedGeneration: 7,
    });

    expect(forA.rootPath).toBe("/plugins/acme/demo/1.0.0");
    expect(forB.rootPath).toBe("/user-b/acme/demo");
    expect(reader.cached("user-a")[0]?.rootPath).toBe(
      "/plugins/acme/demo/1.0.0",
    );
    expect(reader.cached("user-b")[0]?.rootPath).toBe("/user-b/acme/demo");
  });

  it("re-reads the authoritative store and denies a stale generation", async () => {
    // Break caught: resolving from the in-memory registry without comparing
    // the persisted generation on every activation boundary.
    const row = approved();
    const reader = createApprovedContributionReader({
      store: new MemoryContributionStore([row]),
    });
    const query = {
      userId: "user-a",
      canonicalId: row.canonicalId,
      installationId: row.installationId,
      expectedDigest: row.digest,
      expectedGeneration: 7,
    };
    await expect(reader.requireActive(query)).resolves.toMatchObject({
      generation: 7,
    });

    row.generation = 8;
    await expect(reader.requireActive(query)).rejects.toBeInstanceOf(
      ContributionActivationError,
    );
    await expect(reader.requireActive(query)).rejects.toMatchObject({
      code: "stale_generation",
    });
  });

  it("never resurrects a deactivated row from cache", async () => {
    // Break caught: treating a cache hit as activation authority after the
    // durable row was disabled or deleted.
    const row = approved();
    const store = new MemoryContributionStore([row]);
    const reader = createApprovedContributionReader({ store });
    const query = {
      userId: "user-a",
      canonicalId: row.canonicalId,
      installationId: row.installationId,
      expectedDigest: row.digest,
      expectedGeneration: row.generation,
    };
    await reader.requireActive(query);
    expect(reader.cached("user-a")).toHaveLength(1);

    row.active = false;
    await expect(reader.requireActive(query)).rejects.toMatchObject({
      code: "inactive",
    });
    expect(reader.cached("user-a")).toEqual([]);

    row.active = true;
    await reader.requireActive(query);
    store.rows.splice(0, 1);
    await expect(reader.requireActive(query)).rejects.toMatchObject({
      code: "not_found",
    });
    expect(reader.cached("user-a")).toEqual([]);
  });

  it("binds activation to the exact installation and digest", async () => {
    // Break caught: checking only canonicalId/generation while an upgrade or
    // another installation supplies different approved content.
    const reader = createApprovedContributionReader({
      store: new MemoryContributionStore([approved()]),
    });
    const query = {
      userId: "user-a",
      canonicalId: approved().canonicalId,
      installationId: "installation-a",
      expectedDigest: "sha256:content-a",
      expectedGeneration: 7,
    };

    await expect(
      reader.requireActive({ ...query, installationId: "installation-old" }),
    ).rejects.toMatchObject({ code: "installation_mismatch" });
    await expect(
      reader.requireActive({ ...query, expectedDigest: "sha256:old" }),
    ).rejects.toMatchObject({ code: "digest_mismatch" });
  });
});

describe("transactional contribution staging/rollback port", () => {
  it("stages and probes before the single atomic commit", async () => {
    // Break caught: activating during stage/probe rather than after all
    // validation completed.
    const events: string[] = [];
    const port: ContributionTransactionPort = {
      async stage() {
        events.push("stage");
        return staged();
      },
      async probe() {
        events.push("probe");
      },
      async commit() {
        events.push("commit");
      },
      async rollback() {
        events.push("rollback");
        return completeRollback();
      },
    };

    await expect(
      runApprovedContributionTransaction(transactionContext, port),
    ).resolves.toEqual({ status: "activated", generation: 7 });
    expect(events).toEqual(["stage", "probe", "commit"]);
  });

  it.each(["stage", "probe", "commit"] as const)(
    "rolls back a %s failure and reports the port's cleanup outcome",
    async (failure) => {
      // Break caught: skipping rollback for an early failure, or claiming
      // cleanup independently of the transactional port's reported outcome.
      const events: string[] = [];
      const port: ContributionTransactionPort = {
        async stage() {
          events.push("stage");
          if (failure === "stage") throw new Error("archive rejected");
          return staged();
        },
        async probe() {
          events.push("probe");
          if (failure === "probe") throw new Error("probe rejected");
        },
        async commit() {
          events.push("commit");
          if (failure === "commit") throw new Error("commit rejected");
        },
        async rollback(_context, stagedValue, phase) {
          events.push(`rollback:${phase}:${stagedValue === null ? "none" : "staged"}`);
          return completeRollback();
        },
      };

      const outcome = await runApprovedContributionTransaction(
        transactionContext,
        port,
      );
      expect(outcome).toEqual({
        status: "rolled_back",
        reason: failure,
        rollback: completeRollback(),
      });
      expect(events).toEqual(
        failure === "stage"
          ? ["stage", "rollback:stage:none"]
          : failure === "probe"
            ? ["stage", "probe", "rollback:probe:staged"]
            : ["stage", "probe", "commit", "rollback:commit:staged"],
      );
    },
  );

  it.each([
    "previousVersionPreserved",
    "stagingRemoved",
    "spawnedProcessesStopped",
    "newConnectionsRemoved",
    "newSealedConfigRemoved",
    "newRegistrationsRemoved",
  ] as const)("does not report a clean rollback when %s is false", async (field) => {
    // Break caught: treating a best-effort rollback attempt as proof that the
    // previous version and every newly owned resource were actually handled.
    const rollback = { ...completeRollback(), [field]: false };
    const port: ContributionTransactionPort = {
      async stage() {
        return staged();
      },
      async probe() {
        throw new Error("probe rejected");
      },
      async commit() {},
      async rollback() {
        return rollback;
      },
    };

    await expect(
      runApprovedContributionTransaction(transactionContext, port),
    ).resolves.toEqual({
      status: "rollback_incomplete",
      reason: "probe",
      rollback,
    });
  });

  it("forwards only the exact context and secret-free staged projection", async () => {
    // Break caught: spreading caller/stager objects and accidentally handing
    // pasted fields to a later persistence adapter.
    let receivedContext: ContributionTransactionContext | undefined;
    let receivedStaged: StagedApprovedContributions | undefined;
    const contextWithSecrets = {
      ...transactionContext,
      secrets: { TOKEN: "pasted-secret" },
    } as ContributionTransactionContext;
    const port: ContributionTransactionPort = {
      async stage(context) {
        receivedContext = context;
        return {
          ...staged(),
          pastedConfig: "pasted-secret",
        } as StagedApprovedContributions;
      },
      async probe(value) {
        receivedStaged = value;
      },
      async commit() {},
      async rollback() {
        return completeRollback();
      },
    };

    await expect(
      runApprovedContributionTransaction(contextWithSecrets, port),
    ).resolves.toEqual({ status: "activated", generation: 7 });
    expect(Object.keys(receivedContext ?? {}).sort()).toEqual(
      Object.keys(transactionContext).sort(),
    );
    expect(JSON.stringify(receivedContext)).not.toContain("pasted-secret");
    expect(JSON.stringify(receivedStaged)).not.toContain("pasted-secret");
  });

  it("never forwards a rejected staged object or its secrets to rollback", async () => {
    // Break caught: assigning the raw stage result before normalization, then
    // passing that same secret-bearing object to rollback when approval fails.
    let receivedContext: ContributionTransactionContext | undefined;
    let receivedStaged: StagedApprovedContributions | null | undefined;
    let receivedPhase: "stage" | "probe" | "commit" | undefined;
    const rejected = {
      ...staged(),
      pastedConfig: "top-level-pasted-config-canary",
      secrets: { TOKEN: "top-level-secret-canary" },
      unknown: { nested: "top-level-unknown-canary" },
      contributions: [
        {
          ...approved({ active: false, approvedSourceId: "different-source" }),
          pastedConfig: "nested-pasted-config-canary",
          secrets: { TOKEN: "nested-secret-canary" },
          data: {
            file: "commands/review.md",
            unknown: { nested: "nested-unknown-canary" },
          },
        },
      ],
    } as unknown as StagedApprovedContributions;
    const port: ContributionTransactionPort = {
      async stage() {
        return rejected;
      },
      async probe() {},
      async commit() {},
      async rollback(context, value, phase) {
        receivedContext = context;
        receivedStaged = value;
        receivedPhase = phase;
        return completeRollback();
      },
    };

    const outcome = await runApprovedContributionTransaction(
      transactionContext,
      port,
    );

    expect(outcome).toEqual({
      status: "rolled_back",
      reason: "stage",
      rollback: completeRollback(),
    });
    // Null is deliberate on normalization rejection. Cleanup still receives
    // the exact safe installation/source/digest/generation identity in context.
    expect(receivedStaged).toBeNull();
    expect(receivedContext).toEqual(transactionContext);
    expect(receivedPhase).toBe("stage");
    const serializedBoundary = JSON.stringify({
      outcome,
      context: receivedContext,
      staged: receivedStaged,
    });
    for (const canary of [
      "top-level-pasted-config-canary",
      "top-level-secret-canary",
      "top-level-unknown-canary",
      "nested-pasted-config-canary",
      "nested-secret-canary",
      "nested-unknown-canary",
    ]) {
      expect(serializedBoundary).not.toContain(canary);
    }
    expect(serializedBoundary).not.toContain("pastedConfig");
    expect(serializedBoundary).not.toContain("secrets");
  });

  it("refuses a staged set whose approval binding differs from the context", async () => {
    // Break caught: probing/committing contributions returned for a different
    // installation, digest, or generation than the admitted job.
    const events: string[] = [];
    const port: ContributionTransactionPort = {
      async stage() {
        return { ...staged(), digest: "sha256:different" };
      },
      async probe() {
        events.push("probe");
      },
      async commit() {
        events.push("commit");
      },
      async rollback() {
        events.push("rollback");
        return completeRollback();
      },
    };

    await expect(
      runApprovedContributionTransaction(transactionContext, port),
    ).resolves.toMatchObject({ status: "rolled_back", reason: "stage" });
    expect(events).toEqual(["rollback"]);
  });

  it("surfaces a rollback-port failure as incomplete, never as success", async () => {
    // Break caught: swallowing cleanup errors and returning rolled_back.
    const port: ContributionTransactionPort = {
      async stage() {
        return staged();
      },
      async probe() {
        throw new Error("probe rejected");
      },
      async commit() {},
      async rollback() {
        throw new Error("cleanup unavailable");
      },
    };

    await expect(
      runApprovedContributionTransaction(transactionContext, port),
    ).resolves.toEqual({
      status: "rollback_incomplete",
      reason: "probe",
      rollback: null,
    });
  });
});
