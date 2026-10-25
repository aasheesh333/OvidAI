import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, newId, sessions, users, workspaceObjects, type Db } from "@ovid/db";
import { createStorage, type StorageAdapter } from "@ovid/storage";
import { createMigrationScratch, type MigrationScratch } from "../../../packages/db/src/migrationTestKit.js";
import { TEST_DATABASE_URL, testUid } from "./test/db.js";
import { StorageQuota } from "./storageQuota.js";

const NOW = new Date("2026-10-24T12:00:00.000Z");

describe.skipIf(!TEST_DATABASE_URL)("gateway storage quotas and immutable shares (isolated Postgres + fs)", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let root: string;
  let storage: StorageAdapter;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "gateway_storage_quota");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
    root = await mkdtemp(join(tmpdir(), "ovid-storage-quota-gateway-"));
    storage = createStorage({ backend: "fs", fsRoot: root });
  }, 180_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
    await rm(root, { recursive: true, force: true });
  }, 30_000);

  async function source(content = "frozen-v1", contentType = "text/plain") {
    const actorUserId = testUid("share-owner");
    await users.ensure(db, actorUserId, null);
    const session = await sessions.create(db, actorUserId, "share source");
    const artifactId = newId();
    const versionHash = createHash("sha256").update(content).digest("hex");
    const key = `users/${actorUserId}/artifacts/${session.id}/${artifactId}-${versionHash.slice(0, 16)}-source.txt`;
    await storage.put(key, Buffer.from(content), {
      contentType,
      sha256Hex: versionHash,
      metadata: { probe: "preserved" },
    });
    await workspaceObjects.registerArtifact(db, {
      id: artifactId,
      userId: actorUserId,
      sessionId: session.id,
      r2Key: key,
      bytes: Buffer.byteLength(content),
      sha256: versionHash,
      contentType,
      meta: { name: "source.txt" },
    });
    return { actorUserId, sessionId: session.id, artifactId, key, versionHash, content };
  }

  function service() {
    return new StorageQuota({ db, storage, now: () => NOW });
  }

  it("reference-counts independent grants and charges one frozen copy once", async () => {
    const fixture = await source();
    const quota = service();
    const first = await quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "first.txt",
    });
    const second = await quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "second.txt",
    });
    expect(first.grantId).not.toBe(second.grantId);
    expect(first.key).toBe(second.key);
    expect(first.key).toContain(`sha256-${fixture.versionHash}`);
    expect(first.versionHash).toBe(fixture.versionHash);
    expect(first.cacheClass).toBe("immutable");
    expect(await quota.storageUsage(fixture.actorUserId))
      .toEqual({ usedBytes: 2 * Buffer.byteLength(fixture.content), reservedBytes: 0 });
    expect(await quota.assertActive(first.grantId, fixture.versionHash)).toBe(true);
    expect(await quota.assertActive(first.grantId, "0".repeat(64))).toBe(false);

    // Mutating the original never mutates the frozen shared version.
    await storage.put(fixture.key, Buffer.from("overwritten-v2"), { contentType: "text/plain" });
    expect((await storage.getBuffer(first.key))!.toString()).toBe(fixture.content);

    expect(await quota.revokeImmutableShare({
      actorUserId: fixture.actorUserId,
      grantId: first.grantId,
    })).toEqual({ revoked: true, objectRemoved: false });
    expect(await quota.assertActive(first.grantId, fixture.versionHash)).toBe(false);
    expect(await quota.assertActive(second.grantId, fixture.versionHash)).toBe(true);
    expect(await storage.head(first.key)).not.toBeNull();
    expect(await quota.storageUsage(fixture.actorUserId))
      .toEqual({ usedBytes: 2 * Buffer.byteLength(fixture.content), reservedBytes: 0 });

    expect(await quota.revokeImmutableShare({
      actorUserId: fixture.actorUserId,
      grantId: second.grantId,
    })).toEqual({ revoked: true, objectRemoved: true });
    expect(await quota.revokeImmutableShare({
      actorUserId: fixture.actorUserId,
      grantId: second.grantId,
    })).toEqual({ revoked: false, objectRemoved: false });
    expect(await quota.storageUsage(fixture.actorUserId))
      .toEqual({ usedBytes: Buffer.byteLength(fixture.content), reservedBytes: 0 });
    expect(await storage.head(first.key)).toBeNull();

    // A later share of the same source version starts a fresh charged copy.
    await storage.put(fixture.key, Buffer.from(fixture.content), {
      contentType: "text/plain",
      sha256Hex: fixture.versionHash,
    });
    const recreated = await quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "recreated.txt",
    });
    expect(recreated.versionHash).toBe(fixture.versionHash);
    expect(await quota.assertActive(recreated.grantId, fixture.versionHash)).toBe(true);
    expect(await quota.storageUsage(fixture.actorUserId))
      .toEqual({ usedBytes: 2 * Buffer.byteLength(fixture.content), reservedBytes: 0 });
  });

  it("charges one frozen copy across concurrent grants and preserves the last reference", async () => {
    const fixture = await source();
    let waiting = 0;
    let releaseHeads!: () => void;
    const bothHeads = new Promise<void>((resolve) => { releaseHeads = resolve; });
    const raced: StorageAdapter = {
      ...storage,
      head: async (key) => {
        const result = await storage.head(key);
        if (result === null && key.includes("/artifact-shares/")) {
          waiting += 1;
          if (waiting === 2) releaseHeads();
          await bothHeads;
        }
        return result;
      },
    };
    const quota = new StorageQuota({ db, storage: raced, now: () => NOW });
    const [first, second] = await Promise.all([
      quota.createImmutableShare({
        actorUserId: fixture.actorUserId,
        artifactId: fixture.artifactId,
        displayName: "first.txt",
      }),
      quota.createImmutableShare({
        actorUserId: fixture.actorUserId,
        artifactId: fixture.artifactId,
        displayName: "second.txt",
      }),
    ]);
    expect(first.key).toBe(second.key);
    expect(await quota.storageUsage(fixture.actorUserId))
      .toEqual({ usedBytes: 2 * Buffer.byteLength(fixture.content), reservedBytes: 0 });
    await quota.revokeImmutableShare({ actorUserId: fixture.actorUserId, grantId: first.grantId });
    expect(await storage.head(first.key)).not.toBeNull();
    await quota.revokeImmutableShare({ actorUserId: fixture.actorUserId, grantId: second.grantId });
    expect(await storage.head(first.key)).toBeNull();
    expect(await quota.storageUsage(fixture.actorUserId))
      .toEqual({ usedBytes: Buffer.byteLength(fixture.content), reservedBytes: 0 });
  });

  it("refuses a share when actual frozen-copy hash evidence is missing or changed", async () => {
    const fixture = await source();
    const withoutHash: StorageAdapter = {
      ...storage,
      head: async (key) => {
        const head = await storage.head(key);
        return head === null ? null : { ...head, sha256Hex: null };
      },
    };
    const quota = new StorageQuota({ db, storage: withoutHash, now: () => NOW });
    await expect(quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "unverifiable.txt",
    })).rejects.toMatchObject({ code: "artifact_version_unknown" });
    expect(await quota.storageUsage(fixture.actorUserId))
      .toEqual({ usedBytes: Buffer.byteLength(fixture.content), reservedBytes: 0 });
  });

  // UNEXECUTED under the 2026-10-25 heavy-verification pause.
  it("fails grant assertion when the real charged copy was retired independently", async () => {
    const fixture = await source();
    const quota = service();
    const share = await quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "charge-fenced.txt",
    });
    const chargeId = `artifact-share:${fixture.artifactId}:${fixture.versionHash}`;
    expect(await quota.removeObject({ reservationId: chargeId }))
      .toEqual({ removed: true, freedBytes: Buffer.byteLength(fixture.content) });
    // The grant row itself is still finalized; assertion must nevertheless fail
    // because the independently reference-counted real copy is no longer live.
    expect(await quota.assertActive(share.grantId, fixture.versionHash)).toBe(false);
    await quota.revokeImmutableShare({ actorUserId: fixture.actorUserId, grantId: share.grantId });
  });

  // UNEXECUTED under the 2026-10-25 heavy-verification pause.
  it("uses the source tombstone to fence new shares and retries orphan cleanup", async () => {
    const fixture = await source();
    let failDelete = true;
    const raced: StorageAdapter = {
      ...storage,
      delete: async (key) => {
        if (failDelete && key.includes("/artifact-shares/")) throw new Error("injected delete outage");
        await storage.delete(key);
      },
    };
    const quota = new StorageQuota({ db, storage: raced, now: () => NOW });
    const share = await quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "cleanup.txt",
    });
    await db.$client`UPDATE workspace_objects SET status = 'deleted' WHERE id = ${fixture.artifactId}`;
    await quota.revokeArtifactShares(fixture.actorUserId, fixture.artifactId);
    expect(await quota.assertActive(share.grantId, fixture.versionHash)).toBe(false);
    expect(await storage.head(share.key)).not.toBeNull();
    failDelete = false;
    // Round-1 UNEXECUTED regression: retry through source deletion, not the
    // single-grant method. Released grants must remain discoverable here.
    await quota.revokeArtifactShares(fixture.actorUserId, fixture.artifactId);
    expect(await storage.head(share.key)).toBeNull();

    await expect(quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "after-delete.txt",
    })).rejects.toMatchObject({ code: "artifact_not_found" });
  });

  it("forces active HTML, SVG and XML shares to attachment disposition", async () => {
    for (const contentType of ["text/html", "image/svg+xml", "application/xml"]) {
      const fixture = await source(`<root>${contentType}</root>`, contentType);
      const grant = await service().createImmutableShare({
        actorUserId: fixture.actorUserId,
        artifactId: fixture.artifactId,
        displayName: "active.html",
      });
      expect(grant.disposition).toBe("attachment");
      expect(grant.contentType).toBe(contentType);
    }
  });

  it("does not let another account revoke or enumerate a grant", async () => {
    const fixture = await source();
    const quota = service();
    const grant = await quota.createImmutableShare({
      actorUserId: fixture.actorUserId,
      artifactId: fixture.artifactId,
      displayName: "private.txt",
    });
    const other = testUid("share-stranger");
    await users.ensure(db, other, null);
    expect(await quota.revokeImmutableShare({ actorUserId: other, grantId: grant.grantId }))
      .toEqual({ revoked: false, objectRemoved: false });
    expect(await quota.assertActive(grant.grantId, fixture.versionHash)).toBe(true);
    await expect(quota.createImmutableShare({
      actorUserId: other,
      artifactId: fixture.artifactId,
      displayName: "stolen.txt",
    })).rejects.toMatchObject({ code: "artifact_not_found" });
  });
});
