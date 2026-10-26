import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { planFor } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { mcpOauthTokens, newId, users } from "./repos.js";
import type { SealedEnvelope } from "./schema.js";
import {
  createConnectionWithinCap,
  disconnectConnection,
  normalizeConnectionName,
  recordConnectionHealth,
  revalidateConnection,
  transitionConnection,
  type CreateConnectionInput,
} from "./providerConnections.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

function sealForTest(plaintext: string, connectionId: string): SealedEnvelope {
  // The repository consumes an opaque sealing port. Real AES-GCM/AAD behavior
  // is exercised by the gateway route tests with the production crypto.
  return {
    wrappedDek: `sealed-for:${connectionId}`,
    iv: "test-iv",
    ciphertext: Buffer.from(plaintext, "utf8").toString("base64"),
    tag: "test-tag",
  };
}

function createInput(uid: string, name: string, overrides: Partial<CreateConnectionInput> = {}): CreateConnectionInput {
  return {
    userId: uid,
    kind: "custom",
    providerId: "custom",
    name,
    normalizedConnectionName: normalizeConnectionName(name),
    transport: "http",
    config: { url: "https://connector.example.test/mcp" },
    agentEnabled: false,
    authState: "needs_auth",
    ...overrides,
  };
}

async function seedUser(db: Db, tier: string): Promise<string> {
  const uid = newId();
  await users.ensure(db, uid, `${uid}@test.local`);
  await db.$client.unsafe("UPDATE users SET tier = $2 WHERE uid = $1", [uid, tier]);
  return uid;
}

function errorCode(result: PromiseRejectedResult): unknown {
  return (result.reason as { code?: unknown }).code;
}

describe.skipIf(!TEST_DATABASE_URL)("provider connections against isolated real Postgres", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "provider_connections");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 16 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  it("enforces cap and uniqueness across concurrent creates", async () => {
    const uid = await seedUser(db, "go");
    const plan = planFor("go");
    const attempted = await Promise.allSettled(
      Array.from({ length: plan.customConnectors + 4 }, (_, index) =>
        createConnectionWithinCap(db, createInput(uid, `Cap ${index}`)),
      ),
    );
    const succeeded = attempted.filter((result) => result.status === "fulfilled");
    const refused = attempted.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    expect(succeeded).toHaveLength(plan.customConnectors);
    expect(refused).toHaveLength(4);
    expect(refused.every((result) => errorCode(result) === "connector_limit_reached")).toBe(true);
    const capRows = await db.$client.unsafe(
      "SELECT normalized_connection_name FROM mcp_servers WHERE user_id = $1 AND curated_id IS NULL",
      [uid],
    );
    expect(capRows).toHaveLength(plan.customConnectors);
    expect(new Set(capRows.map((row) => row.normalized_connection_name)).size).toBe(capRows.length);

    const duplicateUid = await seedUser(db, "pro");
    const duplicateCustom = await Promise.allSettled(
      Array.from({ length: 6 }, (_, index) =>
        createConnectionWithinCap(
          db,
          createInput(duplicateUid, index % 2 === 0 ? "  Mixed Case  " : "mixed case"),
        ),
      ),
    );
    expect(duplicateCustom.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(
      duplicateCustom
        .filter((result): result is PromiseRejectedResult => result.status === "rejected")
        .every((result) => errorCode(result) === "server_exists"),
    ).toBe(true);

    const duplicateCurated = await Promise.allSettled(
      Array.from({ length: 6 }, (_, index) =>
        createConnectionWithinCap(
          db,
          createInput(duplicateUid, `GitHub ${index}`, {
            kind: "curated",
            providerId: "github",
            transport: "native",
            config: null,
            authState: "missing",
          }),
        ),
      ),
    );
    expect(duplicateCurated.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(
      duplicateCurated
        .filter((result): result is PromiseRejectedResult => result.status === "rejected")
        .every((result) => errorCode(result) === "server_exists"),
    ).toBe(true);

    const identityRows = await db.$client.unsafe(
      "SELECT provider_id, normalized_connection_name, curated_id FROM mcp_servers WHERE user_id = $1",
      [duplicateUid],
    );
    expect(identityRows).toHaveLength(2);
    expect(identityRows.filter((row) => row.provider_id === "github")).toHaveLength(1);
    expect(identityRows.filter((row) => row.curated_id === null)).toHaveLength(1);

    const sourceUid = await seedUser(db, "pro");
    await createConnectionWithinCap(
      db,
      createInput(sourceUid, "Source Name A", { approvedSourceId: "source-a", approvedDigest: "digest-a" }),
    );
    await expect(
      createConnectionWithinCap(
        db,
        createInput(sourceUid, "Source Name B", { approvedSourceId: "source-b", approvedDigest: "digest-b" }),
      ),
    ).resolves.toMatchObject({ approvedSourceId: "source-b", approvedDigest: "digest-b" });
    await expect(
      createConnectionWithinCap(
        db,
        createInput(sourceUid, "SOURCE NAME A", { approvedSourceId: "source-a", approvedDigest: "digest-a" }),
      ),
    ).rejects.toMatchObject({ code: "server_exists" });
  }, 30_000);

  it("enforces sanitized custom-name uniqueness inside concurrent transactional admission", async () => {
    const uid = await seedUser(db, "pro");
    const attempts = await Promise.allSettled(
      ["fetch", "Fetch!", "fetch!!", "FETCH", " fetch ", "Fetch"].map((name) =>
        createConnectionWithinCap(db, createInput(uid, name)),
      ),
    );
    expect(attempts.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(
      attempts
        .filter((result): result is PromiseRejectedResult => result.status === "rejected")
        .every((result) => errorCode(result) === "server_exists"),
    ).toBe(true);

    await expect(
      createConnectionWithinCap(db, createInput(uid, "fetch-client")),
    ).resolves.toMatchObject({ name: "fetch-client" });
    await expect(
      createConnectionWithinCap(db, createInput(uid, "fetch client")),
    ).resolves.toMatchObject({ name: "fetch client" });
    await expect(
      createConnectionWithinCap(db, createInput(uid, "Fetch Client!")),
    ).rejects.toMatchObject({ code: "server_exists" });

    const rows = await db.$client.unsafe(
      "SELECT name FROM mcp_servers WHERE user_id = $1 AND curated_id IS NULL ORDER BY name",
      [uid],
    );
    expect(rows).toHaveLength(3);
    expect(rows.map((row) => row.name)).toEqual(expect.arrayContaining(["fetch client", "fetch-client"]));
    expect(rows.filter((row) => !["fetch client", "fetch-client"].includes(row.name))).toHaveLength(1);
  }, 15_000);

  it("enforces one per-user namespace across approved-source identities without losing source identity", async () => {
    const uid = await seedUser(db, "pro");
    const attempts = await Promise.allSettled([
      createConnectionWithinCap(db, createInput(uid, "Shared Namespace", {
        approvedSourceId: "source-a",
        approvedDigest: "digest-a",
      })),
      createConnectionWithinCap(db, createInput(uid, "shared namespace!", {
        approvedSourceId: "source-b",
        approvedDigest: "digest-b",
      })),
    ]);
    expect(attempts.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(attempts.filter((result) => result.status === "rejected")).toHaveLength(1);
    const fulfilled = attempts.find((result): result is PromiseFulfilledResult<Awaited<ReturnType<typeof createConnectionWithinCap>>> =>
      result.status === "fulfilled",
    );
    const sourceId = fulfilled!.value.approvedSourceId;
    const digest = fulfilled!.value.approvedDigest;
    await expect(
      createConnectionWithinCap(db, createInput(uid, "SHARED NAMESPACE", {
        approvedSourceId: sourceId,
        approvedDigest: digest,
      })),
    ).rejects.toMatchObject({ code: "server_exists" });
    await expect(
      createConnectionWithinCap(db, createInput(uid, "Distinct Namespace", {
        approvedSourceId: sourceId === "source-a" ? "source-b" : "source-a",
        approvedDigest: sourceId === "source-a" ? "digest-b" : "digest-a",
      })),
    ).resolves.toMatchObject({ name: "Distinct Namespace" });
    const rows = await db.$client.unsafe(
      "SELECT approved_source_id, approved_digest FROM mcp_servers WHERE user_id = $1",
      [uid],
    );
    expect(rows).toHaveLength(2);
    expect(rows).toContainEqual({ approved_source_id: sourceId, approved_digest: digest });

    // Per-user global does not mean cross-user global.
    const otherUid = await seedUser(db, "pro");
    await expect(
      createConnectionWithinCap(db, createInput(otherUid, "Shared Namespace", {
        approvedSourceId: "source-b",
        approvedDigest: "digest-b",
      })),
    ).resolves.toMatchObject({ userId: otherUid, name: "Shared Namespace" });
  }, 15_000);

  it("collides NFKC/case/punctuation variants transactionally without merging genuinely different names", async () => {
    const uid = await seedUser(db, "pro");
    const fullwidthDecomposed = "\uFF45\u0301\uFF43\uFF4C\uFF41\uFF49\uFF52";
    const attempts = await Promise.allSettled(
      ["éclair", "e\u0301clair", "ÉCLAIR!", fullwidthDecomposed].map((name) =>
        createConnectionWithinCap(db, createInput(uid, name)),
      ),
    );
    expect(attempts.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(
      attempts
        .filter((result): result is PromiseRejectedResult => result.status === "rejected")
        .every((result) => errorCode(result) === "server_exists"),
    ).toBe(true);

    for (const distinct of ["eclair", "e-clair", "e clair"]) {
      await expect(createConnectionWithinCap(db, createInput(uid, distinct)))
        .resolves.toMatchObject({ name: distinct });
    }
    expect(normalizeConnectionName("  Ｆｅｔｃｈ  ")).toBe("fetch");
    expect(normalizeConnectionName("e\u0301clair")).toBe(normalizeConnectionName("éclair"));
    expect(normalizeConnectionName("eclair")).not.toBe(normalizeConnectionName("éclair"));
  }, 15_000);

  it("re-reads the current plan after waiting for the per-user admission lock", async () => {
    const uid = await seedUser(db, "pro");
    let releaseLock!: () => void;
    let markLocked!: () => void;
    const locked = new Promise<void>((resolve) => { markLocked = resolve; });
    const gate = new Promise<void>((resolve) => { releaseLock = resolve; });
    const holder = db.$client.begin(async (tx) => {
      await tx.unsafe("select pg_advisory_xact_lock(hashtextextended($1, 0))", [`custom-connectors:${uid}`]);
      markLocked();
      await gate;
    });
    await locked;
    try {
      const pending = createConnectionWithinCap(db, createInput(uid, "Downgrade race"));
      await db.$client.unsafe("UPDATE users SET tier = 'free' WHERE uid = $1", [uid]);
      releaseLock();
      await expect(pending).rejects.toMatchObject({ code: "connector_limit_reached", limit: 0 });
      await holder;
      const rows = await db.$client.unsafe("SELECT id FROM mcp_servers WHERE user_id = $1", [uid]);
      expect(rows).toHaveLength(0);
    } finally {
      releaseLock();
      await holder.catch(() => {});
    }
  }, 15_000);

  it("enforces global NFKC namespaces on rename while excluding only the same row", async () => {
    const uid = await seedUser(db, "pro");
    const alpha = await createConnectionWithinCap(db, createInput(uid, "Alpha", {
      approvedSourceId: "source-a",
      approvedDigest: "digest-a",
    }));
    const beta = await createConnectionWithinCap(db, createInput(uid, "Beta", {
      approvedSourceId: "source-b",
      approvedDigest: "digest-b",
    }));
    const expected = { configVersion: 1, disconnectGeneration: 0 };

    await expect(transitionConnection(db, beta.connectionId, uid, { name: "Alpha!" }, expected))
      .rejects.toMatchObject({ code: "server_exists" });
    await expect(transitionConnection(db, beta.connectionId, uid, {
      name: "fetch",
      isNamespaceReserved: (name) => name === "fetch",
    }, expected)).rejects.toMatchObject({ code: "server_exists" });
    expect(await revalidateConnection(db, beta.connectionId, uid, expected)).toBe("denied");

    const sameSourceTarget = await createConnectionWithinCap(db, createInput(uid, "Same Source Occupied", {
      approvedSourceId: "source-shared",
      approvedDigest: "digest-shared",
    }));
    const sameSourceCandidate = await createConnectionWithinCap(db, createInput(uid, "Same Source Candidate", {
      approvedSourceId: "source-shared",
      approvedDigest: "digest-shared",
    }));
    expect(sameSourceTarget.approvedSourceId).toBe(sameSourceCandidate.approvedSourceId);
    await expect(transitionConnection(db, sameSourceCandidate.connectionId, uid, {
      name: "same source occupied!",
    }, expected)).rejects.toMatchObject({ code: "server_exists" });

    expect(await transitionConnection(db, beta.connectionId, uid, { name: "Gamma" }, {
      configVersion: 0,
      disconnectGeneration: 0,
    })).toBeNull();
    expect(await transitionConnection(db, beta.connectionId, uid, { name: "Gamma" }, {
      configVersion: 1,
      disconnectGeneration: 1,
    })).toBeNull();

    const unicode = await createConnectionWithinCap(db, createInput(uid, "éclair"));
    await expect(transitionConnection(db, beta.connectionId, uid, { name: "e\u0301clair!" }, expected))
      .rejects.toMatchObject({ code: "server_exists" });
    await expect(transitionConnection(db, beta.connectionId, uid, { name: "eclair" }, expected))
      .resolves.toMatchObject({ name: "eclair", configVersion: 2, disconnectGeneration: 0 });

    // A legitimate same-source rename is not an idempotency conflict.
    await expect(transitionConnection(db, alpha.connectionId, uid, { name: "Alpha Renamed" }, expected))
      .resolves.toMatchObject({
        connectionId: alpha.connectionId,
        name: "Alpha Renamed",
        approvedSourceId: "source-a",
        approvedDigest: "digest-a",
        configVersion: 2,
        disconnectGeneration: 0,
      });
    await expect(transitionConnection(db, alpha.connectionId, uid, { name: "Alpha!" }, {
      configVersion: 2,
      disconnectGeneration: 0,
    })).resolves.toMatchObject({ name: "Alpha!", configVersion: 3 });

    // The row itself is excluded from its collision set; every other row still applies.
    await expect(transitionConnection(db, alpha.connectionId, uid, { name: "ALPHA!" }, {
      configVersion: 3,
      disconnectGeneration: 0,
    }))
      .resolves.toMatchObject({ name: "ALPHA!", configVersion: 4 });
    await expect(transitionConnection(db, unicode.connectionId, uid, { name: "eclair" }, expected))
      .rejects.toMatchObject({ code: "server_exists" });

    // A first user's occupied target remains present throughout the other user's
    // successful rename: namespace uniqueness is per-user, not cross-user.
    const occupied = await createConnectionWithinCap(db, createInput(uid, "Cross User Rename", {
      approvedSourceId: "source-a",
      approvedDigest: "digest-a",
    }));
    const otherUid = await seedUser(db, "pro");
    const other = await createConnectionWithinCap(db, createInput(otherUid, "Other", {
      approvedSourceId: "source-a",
      approvedDigest: "digest-a",
    }));
    await expect(transitionConnection(db, other.connectionId, otherUid, {
      name: "cross user rename!",
    }, expected)).resolves.toMatchObject({
      userId: otherUid,
      name: "cross user rename!",
      configVersion: 2,
      disconnectGeneration: 0,
    });
    const simultaneous = await db.$client.unsafe(
      "SELECT user_id, name FROM mcp_servers WHERE id = ANY($1::text[])",
      [[occupied.connectionId, other.connectionId]],
    );
    expect(simultaneous).toEqual(expect.arrayContaining([
      { user_id: uid, name: "Cross User Rename" },
      { user_id: otherUid, name: "cross user rename!" },
    ]));
  }, 15_000);

  it("serializes concurrent renames into one sanitized namespace without weakening generation fences", async () => {
    const uid = await seedUser(db, "pro");
    const first = await createConnectionWithinCap(db, createInput(uid, "First", {
      approvedSourceId: "source-a",
      approvedDigest: "digest-a",
    }));
    const second = await createConnectionWithinCap(db, createInput(uid, "Second", {
      approvedSourceId: "source-b",
      approvedDigest: "digest-b",
    }));
    const expected = { configVersion: 1, disconnectGeneration: 0 };
    const attempts = await Promise.allSettled([
      transitionConnection(db, first.connectionId, uid, { name: "Shared Rename" }, expected),
      transitionConnection(db, second.connectionId, uid, { name: "shared rename!" }, expected),
    ]);
    const fulfilled = attempts.filter((result) => result.status === "fulfilled");
    const rejected = attempts.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    expect(fulfilled).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    expect(errorCode(rejected[0]!)).toBe("server_exists");

    const winner = fulfilled[0]!.status === "fulfilled" ? fulfilled[0]!.value : null;
    expect(winner).not.toBeNull();
    expect(winner!.configVersion).toBe(2);
    const loserId = winner!.connectionId === first.connectionId ? second.connectionId : first.connectionId;
    expect(await revalidateConnection(db, loserId, uid, expected)).toBe("denied");
    expect(await revalidateConnection(db, winner!.connectionId, uid, expected)).toBe("stale");
    const rows = await db.$client.unsafe(
      "SELECT id, name, config_version FROM mcp_servers WHERE user_id = $1 ORDER BY id",
      [uid],
    );
    expect(rows).toHaveLength(2);
    expect(rows.filter((row) => row.name.toLowerCase().includes("shared rename"))).toHaveLength(1);
    expect(rows.find((row) => row.id === loserId)?.config_version).toBe(1);
  }, 15_000);

  it("fences a stale generation and keeps IDs across rename", async () => {
    const uid = await seedUser(db, "pro");
    const created = await createConnectionWithinCap(
      db,
      createInput(uid, "Original", { authState: "configured" }),
    );
    expect(created).toMatchObject({ configVersion: 1, disconnectGeneration: 0, agentEnabled: false });

    const activated = await transitionConnection(
      db,
      created.connectionId,
      uid,
      { agentEnabled: true },
      { configVersion: 1, disconnectGeneration: 0 },
    );
    expect(activated).toMatchObject({ configVersion: 2, agentEnabled: true });

    const renamed = await transitionConnection(
      db,
      created.connectionId,
      uid,
      { name: "Renamed" },
      { configVersion: 2, disconnectGeneration: 0 },
    );
    expect(renamed).toMatchObject({
      connectionId: created.connectionId,
      userId: uid,
      providerId: "custom",
      name: "Renamed",
      normalizedConnectionName: "renamed",
      configVersion: 3,
      disconnectGeneration: 0,
    });
    expect(await revalidateConnection(db, created.connectionId, uid, {
      configVersion: 3,
      disconnectGeneration: 0,
    })).toBe("current");
    expect(await revalidateConnection(db, created.connectionId, uid, {
      configVersion: 2,
      disconnectGeneration: 0,
    })).toBe("stale");
    await mcpOauthTokens.put(db, {
      userId: uid,
      serverId: created.connectionId,
      tokensSealed: sealForTest("oauth-token-never-survive-disconnect", created.connectionId),
    });
    await expect(disconnectConnection(db, created.connectionId, uid, 2)).resolves.toBeNull();
    expect(await mcpOauthTokens.get(db, created.connectionId, uid)).not.toBeNull();

    const disconnected = await disconnectConnection(db, created.connectionId, uid, 3);
    expect(disconnected).toMatchObject({
      connectionId: created.connectionId,
      providerId: "custom",
      configVersion: 3,
      disconnectGeneration: 1,
      enabled: false,
      agentEnabled: false,
      authState: "revoked",
      healthState: "revoked",
    });
    expect(await mcpOauthTokens.get(db, created.connectionId, uid)).toBeNull();
    expect(await revalidateConnection(db, created.connectionId, uid, {
      configVersion: 3,
      disconnectGeneration: 0,
    })).toBe("stale");
    expect(await revalidateConnection(db, created.connectionId, uid, {
      configVersion: 3,
      disconnectGeneration: 1,
    })).toBe("denied");
    expect(await revalidateConnection(db, created.connectionId, newId(), {
      configVersion: 3,
      disconnectGeneration: 1,
    })).toBe("denied");
  });

  it("seals during admission and fences secret replacement with configVersion", async () => {
    const uid = await seedUser(db, "pro");
    const seenRecordIds: string[] = [];
    const created = await createConnectionWithinCap(
      db,
      createInput(uid, "Secret connection", {
        secrets: { TOKEN: "first-secret-never-store-plain" },
        sealSecrets: (plaintext, recordId) => {
          seenRecordIds.push(recordId);
          return sealForTest(plaintext, recordId.replace(/^mcp_servers:/, ""));
        },
        authState: "configured",
      }),
    );
    expect(created.agentEnabled).toBe(false);
    expect(created.secretsSealed).not.toBeNull();
    expect(seenRecordIds).toEqual([`mcp_servers:${created.connectionId}`]);
    const raw = await db.$client.unsafe("SELECT * FROM mcp_servers WHERE id = $1", [created.connectionId]);
    expect(JSON.stringify(raw[0])).not.toContain("first-secret-never-store-plain");

    const priorCheck = new Date("2026-10-24T12:00:00.000Z");
    await db.$client.unsafe(
      "UPDATE mcp_servers SET health_state = 'healthy', last_checked_at = $2, last_success_at = $2 WHERE id = $1",
      [created.connectionId, priorCheck.toISOString()],
    );

    const replaced = await transitionConnection(
      db,
      created.connectionId,
      uid,
      {
        secrets: { TOKEN: "second-secret-never-store-plain" },
        sealSecrets: (plaintext, recordId) => sealForTest(plaintext, recordId.replace(/^mcp_servers:/, "")),
        authState: "configured",
      },
      { configVersion: 1, disconnectGeneration: 0 },
    );
    expect(replaced).toMatchObject({
      configVersion: 2,
      connectionId: created.connectionId,
      healthState: "never_checked",
      lastCheckedAt: null,
      lastSuccessAt: null,
    });
    expect(await revalidateConnection(db, created.connectionId, uid, {
      configVersion: 1,
      disconnectGeneration: 0,
    })).toBe("stale");
    const after = await db.$client.unsafe("SELECT * FROM mcp_servers WHERE id = $1", [created.connectionId]);
    expect(JSON.stringify(after[0])).not.toContain("second-secret-never-store-plain");
    expect(JSON.stringify(after[0])).not.toContain("first-secret-never-store-plain");

    // A later health writer may record new evidence; the credential transition
    // itself did not preserve or fabricate the prior successful probe.
    const subsequentCheck = new Date("2026-10-24T12:05:00.000Z");
    await db.$client.unsafe(
      "UPDATE mcp_servers SET health_state = 'healthy', last_checked_at = $2, last_success_at = $2 WHERE id = $1",
      [created.connectionId, subsequentCheck.toISOString()],
    );
    const probed = await db.$client.unsafe(
      "SELECT health_state, last_checked_at, last_success_at FROM mcp_servers WHERE id = $1",
      [created.connectionId],
    );
    expect(probed[0]?.health_state).toBe("healthy");
    expect(new Date(probed[0]!.last_checked_at).toISOString()).toBe(subsequentCheck.toISOString());
    expect(new Date(probed[0]!.last_success_at).toISOString()).toBe(subsequentCheck.toISOString());
  });

  it("records fenced health evidence without changing config or disconnect generations", async () => {
    const uid = await seedUser(db, "pro");
    const created = await createConnectionWithinCap(
      db,
      createInput(uid, "Health evidence", { authState: "configured" }),
    );
    const priorSuccess = new Date("2026-10-24T12:00:00.000Z");
    await db.$client.unsafe(
      "UPDATE mcp_servers SET health_state = 'healthy', last_checked_at = $2, last_success_at = $2 WHERE id = $1",
      [created.connectionId, priorSuccess.toISOString()],
    );
    const checkedAt = new Date("2026-10-24T12:05:00.000Z");
    const expected = { configVersion: 1, disconnectGeneration: 0 };

    const degraded = await recordConnectionHealth(
      db,
      created.connectionId,
      uid,
      expected,
      { state: "degraded", checkedAt },
    );
    expect(degraded).toMatchObject({
      healthState: "degraded",
      lastCheckedAt: checkedAt.toISOString(),
      lastSuccessAt: priorSuccess.toISOString(),
      configVersion: 1,
      disconnectGeneration: 0,
    });

    const healthyAt = new Date("2026-10-24T12:06:00.000Z");
    const healthy = await recordConnectionHealth(
      db,
      created.connectionId,
      uid,
      expected,
      { state: "healthy", checkedAt: healthyAt },
    );
    expect(healthy).toMatchObject({
      healthState: "healthy",
      lastCheckedAt: healthyAt.toISOString(),
      lastSuccessAt: healthyAt.toISOString(),
    });

    const staleAt = new Date("2026-10-24T12:07:00.000Z");
    expect(await recordConnectionHealth(
      db,
      created.connectionId,
      newId(),
      expected,
      { state: "healthy", checkedAt: staleAt },
    )).toBeNull();
    expect(await recordConnectionHealth(
      db,
      created.connectionId,
      uid,
      { configVersion: 2, disconnectGeneration: 0 },
      { state: "healthy", checkedAt: staleAt },
    )).toBeNull();
    const row = await db.$client.unsafe(
      "SELECT health_state, last_checked_at, last_success_at, config_version, disconnect_generation FROM mcp_servers WHERE id = $1",
      [created.connectionId],
    );
    expect(row[0]?.health_state).toBe("healthy");
    expect(new Date(row[0]!.last_checked_at).toISOString()).toBe(healthyAt.toISOString());
    expect(new Date(row[0]!.last_success_at).toISOString()).toBe(healthyAt.toISOString());
    expect(row[0]).toMatchObject({ config_version: 1, disconnect_generation: 0 });

    const disconnected = await disconnectConnection(db, created.connectionId, uid, 1);
    expect(disconnected).toMatchObject({ disconnectGeneration: 1, healthState: "revoked" });
    expect(await recordConnectionHealth(
      db,
      created.connectionId,
      uid,
      expected,
      { state: "healthy", checkedAt: staleAt },
    )).toBeNull();
    const afterDisconnect = await db.$client.unsafe(
      "SELECT health_state, last_success_at, disconnect_generation FROM mcp_servers WHERE id = $1",
      [created.connectionId],
    );
    expect(afterDisconnect[0]?.health_state).toBe("revoked");
    expect(new Date(afterDisconnect[0]!.last_success_at).toISOString()).toBe(healthyAt.toISOString());
    expect(afterDisconnect[0]?.disconnect_generation).toBe(1);
  });
});
