import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { byokKeysRepo, createDb, migrate, newId, users, type Db } from "@ovid/db";
import { createEnvelopeCrypto } from "./envelope.js";
import { byokRecordId, createByokKeyProvider } from "./provider.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const KEY = "cd".repeat(32);

function testUid(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

async function seedRow(
  db: Db,
  crypto: ReturnType<typeof createEnvelopeCrypto>,
  opts: { uid: string; apiKey: string; status?: string; corrupt?: boolean },
): Promise<string> {
  await users.ensure(db, opts.uid, null);
  const id = newId();
  const envelope = crypto.encrypt(opts.apiKey, byokRecordId(id));
  if (opts.corrupt) {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const i = Math.floor(envelope.ciphertext.length / 2);
    const replacement = chars[(chars.indexOf(envelope.ciphertext[i]!) + 1) % chars.length]!;
    envelope.ciphertext =
      envelope.ciphertext.slice(0, i) + replacement + envelope.ciphertext.slice(i + 1);
  }
  await byokKeysRepo.create(db, {
    // The repo's create() spreads the row over a generated id, so passing an
    // explicit id pins the id the envelope's AAD was bound to.
    id,
    userId: opts.uid,
    providerId: "openai",
    endpoint: "https://api.example.com/v1",
    label: "test",
    wrappedDek: envelope.wrappedDek,
    iv: envelope.iv,
    ciphertext: envelope.ciphertext,
    tag: envelope.tag,
    status: opts.status ?? "untested",
  } as Parameters<typeof byokKeysRepo.create>[1]);
  return id;
}

describe.skipIf(!TEST_DATABASE_URL)("createByokKeyProvider (real postgres)", () => {
  let db: Db;
  const crypto = createEnvelopeCrypto(KEY);

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  it("decrypts an owned active row", async () => {
    const uid = testUid("byok-provider");
    const id = await seedRow(db, crypto, { uid, apiKey: "sk-worker-SENTINEL-0001" });
    const provider = createByokKeyProvider(db, crypto);
    expect(await provider.getDecrypted(id, uid)).toEqual({
      providerId: "openai",
      endpoint: "https://api.example.com/v1",
      apiKey: "sk-worker-SENTINEL-0001",
    });
  });

  it("returns null for an unknown id or a different owner (no existence leak)", async () => {
    const owner = testUid("byok-provider-owner");
    const id = await seedRow(db, crypto, { uid: owner, apiKey: "sk-owner-only" });
    const provider = createByokKeyProvider(db, crypto);
    expect(await provider.getDecrypted(id, testUid("byok-provider-stranger"))).toBeNull();
    expect(await provider.getDecrypted(newId(), owner)).toBeNull();
  });

  it("returns null for an inactive row", async () => {
    const uid = testUid("byok-provider-inactive");
    const id = await seedRow(db, crypto, { uid, apiKey: "sk-inactive", status: "inactive" });
    const provider = createByokKeyProvider(db, crypto);
    expect(await provider.getDecrypted(id, uid)).toBeNull();
  });

  it("returns null (never throws) on an auth failure and logs it", async () => {
    const uid = testUid("byok-provider-corrupt");
    const id = await seedRow(db, crypto, {
      uid,
      apiKey: "sk-corrupt",
      corrupt: true,
    });
    const logs: string[] = [];
    const provider = createByokKeyProvider(db, crypto, {
      log: (message) => logs.push(message),
    });
    await expect(provider.getDecrypted(id, uid)).resolves.toBeNull();
    expect(logs.length).toBeGreaterThan(0);
    expect(logs.join(" ")).not.toContain("sk-corrupt");
  });

  it("returns null when the master key does not match the row", async () => {
    const uid = testUid("byok-provider-key");
    const id = await seedRow(db, crypto, { uid, apiKey: "sk-other-key" });
    const provider = createByokKeyProvider(db, createEnvelopeCrypto("ef".repeat(32)), {
      log: () => {},
    });
    expect(await provider.getDecrypted(id, uid)).toBeNull();
  });
});
