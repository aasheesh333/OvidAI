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
      createInput(sourceUid, "Source Name", { approvedSourceId: "source-a", approvedDigest: "digest-a" }),
    );
    await expect(
      createConnectionWithinCap(
        db,
        createInput(sourceUid, "source name", { approvedSourceId: "source-b", approvedDigest: "digest-b" }),
      ),
    ).resolves.toMatchObject({ approvedSourceId: "source-b", approvedDigest: "digest-b" });
    await expect(
      createConnectionWithinCap(
        db,
        createInput(sourceUid, "SOURCE NAME", { approvedSourceId: "source-a", approvedDigest: "digest-a" }),
      ),
    ).rejects.toMatchObject({ code: "server_exists" });
  }, 30_000);

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
});
