// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { createDb, migrate, type Db } from "./client.js";
import { createConnectionHealthStore } from "./connectionHealthStore.js";
import { createMigrationScratch, type MigrationScratch } from "./migrationTestKit.js";
import { newId, users } from "./repos.js";
import {
  mcpOauthTokens as tokenTable,
  mcpServers as serverTable,
  type SealedEnvelope,
} from "./schema.js";
import { and, eq } from "drizzle-orm";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const T0 = new Date("2026-10-25T00:00:00.000Z");
const T1 = new Date("2026-10-25T00:01:00.000Z");
const T2 = new Date("2026-10-25T00:02:00.000Z");
const T3 = new Date("2026-10-25T00:03:00.000Z");
const EXPECTED = { configVersion: 4, disconnectGeneration: 2 };

function envelope(value: string): SealedEnvelope {
  return {
    wrappedDek: Buffer.from(`wrapped:${value}`).toString("base64"),
    iv: Buffer.from(`iv:${value}`).toString("base64"),
    ciphertext: Buffer.from(`ciphertext:${value}`).toString("base64"),
    tag: Buffer.from(`tag:${value}`).toString("base64"),
  };
}

describe.skipIf(!TEST_DATABASE_URL)("real connection health store", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "connection_health_store");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
  }, 30_000);

  async function seed() {
    const uid = newId();
    const connectionId = newId();
    await users.ensure(db, uid, `${uid}@test.local`);
    await db.insert(serverTable).values({
      id: connectionId,
      userId: uid,
      name: "GitHub",
      transport: "native",
      curatedId: "github",
      providerId: "github",
      enabled: true,
      agentEnabled: true,
      authState: "authorized",
      healthState: "healthy",
      lastCheckedAt: T0,
      lastSuccessAt: T0,
      configVersion: EXPECTED.configVersion,
      disconnectGeneration: EXPECTED.disconnectGeneration,
    });
    return { uid, connectionId, store: createConnectionHealthStore(db) };
  }

  it("persists checking/refreshing without falsifying completion timestamps and final evidence truthfully", async () => {
    const { uid, connectionId, store } = await seed();
    const input = { connectionId, userId: uid, expected: EXPECTED };

    await expect(store.writeHealth({ ...input, state: "checking" })).resolves.toMatchObject({
      healthState: "checking",
      lastCheckedAt: T0.toISOString(),
      lastSuccessAt: T0.toISOString(),
    });
    await expect(store.writeHealth({ ...input, state: "refreshing" })).resolves.toMatchObject({
      healthState: "refreshing",
      lastCheckedAt: T0.toISOString(),
      lastSuccessAt: T0.toISOString(),
    });
    await expect(store.writeHealth({ ...input, state: "healthy", checkedAt: T1, succeededAt: T1 }))
      .resolves.toMatchObject({
        healthState: "healthy",
        lastCheckedAt: T1.toISOString(),
        lastSuccessAt: T1.toISOString(),
      });
    await expect(store.writeHealth({ ...input, state: "degraded", checkedAt: T2 }))
      .resolves.toMatchObject({
        healthState: "degraded",
        lastCheckedAt: T2.toISOString(),
        lastSuccessAt: T1.toISOString(),
      });
    await expect(store.writeHealth({ ...input, state: "revoked", checkedAt: T3 }))
      .resolves.toMatchObject({
        healthState: "revoked",
        authState: "revoked",
        lastCheckedAt: T3.toISOString(),
        lastSuccessAt: T1.toISOString(),
      });
  });

  it("rejects untruthful evidence and stale config/disconnect writes without changing the row", async () => {
    const { uid, connectionId, store } = await seed();

    await expect(store.writeHealth({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      state: "healthy",
      checkedAt: T1,
    })).rejects.toThrow("healthy_evidence_requires_success");
    await expect(store.writeHealth({
      connectionId,
      userId: uid,
      expected: { configVersion: 3, disconnectGeneration: 2 },
      state: "degraded",
      checkedAt: T1,
    })).resolves.toBeNull();
    await expect(store.writeHealth({
      connectionId,
      userId: uid,
      expected: { configVersion: 4, disconnectGeneration: 1 },
      state: "degraded",
      checkedAt: T1,
    })).resolves.toBeNull();
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      healthState: "healthy",
      lastCheckedAt: T0.toISOString(),
      lastSuccessAt: T0.toISOString(),
    });
  });

  it("makes needs_auth and revoked effective to activation and blocks later revoked token writes", async () => {
    const { uid, connectionId, store } = await seed();

    await expect(store.writeHealth({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      state: "needs_auth",
      checkedAt: T1,
    })).resolves.toMatchObject({ healthState: "needs_auth", authState: "needs_auth" });
    await expect(store.writeHealth({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      state: "revoked",
      checkedAt: T2,
    })).resolves.toMatchObject({ healthState: "revoked", authState: "revoked" });
    await expect(store.writeHealth({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      state: "needs_auth",
      checkedAt: T3,
    })).resolves.toBeNull();
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      healthState: "revoked",
      authState: "revoked",
    });
    await expect(store.writeRefreshedToken({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      token: envelope("revoked-refresh-must-not-write"),
      signal: new AbortController().signal,
    })).resolves.toBe(false);
  });

  it("atomically fences sealed token writes and disconnect cannot be resurrected by an old generation", async () => {
    const { uid, connectionId, store } = await seed();
    const token = envelope("current-token");

    await expect(store.writeRefreshedToken({
      connectionId,
      userId: uid,
      expected: { configVersion: 3, disconnectGeneration: 2 },
      token,
      signal: new AbortController().signal,
    })).resolves.toBe(false);
    await expect(store.writeRefreshedToken({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      token,
      signal: new AbortController().signal,
    })).resolves.toBe(true);
    const before = await db.select().from(tokenTable).where(and(
      eq(tokenTable.serverId, connectionId),
      eq(tokenTable.userId, uid),
    ));
    expect(before).toHaveLength(1);
    expect(before[0]?.tokensSealed).toEqual(token);

    await expect(store.disconnect(connectionId, uid, EXPECTED.configVersion))
      .resolves.toMatchObject({ healthState: "revoked", disconnectGeneration: 3, enabled: false });
    await expect(store.writeRefreshedToken({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      token: envelope("post-disconnect-token"),
      signal: new AbortController().signal,
    })).resolves.toBe(false);
    const after = await db.select().from(tokenTable).where(eq(tokenTable.serverId, connectionId));
    expect(after).toEqual([]);
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      healthState: "revoked",
      disconnectGeneration: 3,
    });
  });

  it("serializes a contended token refresh and disconnect without a final token row", async () => {
    const { uid, connectionId, store } = await seed();
    const other = createConnectionHealthStore(db);

    await Promise.all([
      store.writeRefreshedToken({
        connectionId,
        userId: uid,
        expected: EXPECTED,
        token: envelope("racing-token"),
        signal: new AbortController().signal,
      }),
      other.disconnect(connectionId, uid, EXPECTED.configVersion),
    ]);

    expect(await db.select().from(tokenTable).where(eq(tokenTable.serverId, connectionId))).toEqual([]);
    await expect(store.get(connectionId, uid)).resolves.toMatchObject({
      enabled: false,
      healthState: "revoked",
      disconnectGeneration: 3,
    });
  });

  it("aborts a pending token write and never creates state for a wrong owner", async () => {
    const { uid, connectionId, store } = await seed();
    const controller = new AbortController();
    controller.abort();

    await expect(store.writeRefreshedToken({
      connectionId,
      userId: uid,
      expected: EXPECTED,
      token: envelope("aborted-token"),
      signal: controller.signal,
    })).resolves.toBe(false);
    await expect(store.get(connectionId, "wrong-owner")).resolves.toBeNull();
    expect(await db.select().from(tokenTable).where(eq(tokenTable.serverId, connectionId))).toEqual([]);
  });
});
