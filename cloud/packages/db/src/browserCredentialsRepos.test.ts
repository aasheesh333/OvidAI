import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
// @ovid/db does not depend on @ovid/escrow (dependency direction); the test
// imports the canonical envelope source directly so the crypto under test is
// still the real one.
import { createEnvelopeCrypto } from "../../escrow/src/envelope.js";
import { browserCredentialRecordId } from "@ovid/shared";

import { createDb, migrate, type Db } from "./client.js";
import { browserCredentialsRepo } from "./browserCredentialsRepos.js";
import { newId, users } from "./repos.js";
import { browserCredentials as browserCredentialsTable } from "./schema.js";

/**
 * Wave 6 W4 — the Credentials Vault at rest. Real Postgres: the sealed
 * columns must never contain the plaintext, metadata projections must not
 * select them, and every read/write is owner-scoped.
 */
const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const KEY = "ab".repeat(32);

describe.skipIf(!TEST_DATABASE_URL)("browserCredentialsRepo (W4)", () => {
  let db: Db;
  const crypto = createEnvelopeCrypto(KEY);

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function user(): Promise<string> {
    const uid = `u-${newId()}`;
    await users.ensure(db, uid, `${uid}@example.test`);
    return uid;
  }

  it("stores only ciphertext and lists metadata without the sealed columns", async () => {
    const uid = await user();
    const id = newId();
    const secret = "hunter2-super-secret";
    const notes = "2FA recovery codes are elsewhere";
    const secretSealed = crypto.encrypt(secret, browserCredentialRecordId(id));
    const notesSealed = crypto.encrypt(notes, browserCredentialRecordId(id));

    const created = await browserCredentialsRepo.create(db, {
      id,
      userId: uid,
      label: "Example",
      site: "example.test",
      username: "me@example.test",
      secretKind: "password",
      secretSealed,
      notesSealed,
    });
    expect(created.id).toBe(id);
    expect(created.hasNotes).toBe(true);

    // At rest: the plaintext appears in NO column.
    const [raw] = await db
      .select()
      .from(browserCredentialsTable)
      .where(eq(browserCredentialsTable.id, id));
    const dump = JSON.stringify(raw);
    expect(dump).not.toContain(secret);
    expect(dump).not.toContain(notes);
    expect(crypto.decrypt(raw!.secretSealed, browserCredentialRecordId(id))).toBe(secret);

    // List is metadata only (structurally: no secretSealed key).
    const listed = await browserCredentialsRepo.list(db, uid);
    expect(listed).toHaveLength(1);
    expect(listed[0]).not.toHaveProperty("secretSealed");
    expect(JSON.stringify(listed)).not.toContain(secret);

    // resolve path gets the envelope; wrong owner gets nothing.
    const got = await browserCredentialsRepo.get(db, uid, id);
    expect(got?.secretSealed).toEqual(secretSealed);
    expect(await browserCredentialsRepo.get(db, await user(), id)).toBeNull();
  });

  it("updates a secret in place and clears notes", async () => {
    const uid = await user();
    const id = newId();
    await browserCredentialsRepo.create(db, {
      id,
      userId: uid,
      label: "Example",
      site: "example.test",
      username: "me",
      secretKind: "password",
      secretSealed: crypto.encrypt("old", browserCredentialRecordId(id)),
      notesSealed: crypto.encrypt("note", browserCredentialRecordId(id)),
    });

    const next = crypto.encrypt("new-secret", browserCredentialRecordId(id));
    const updated = await browserCredentialsRepo.update(db, uid, id, {
      label: "Example 2",
      secretSealed: next,
      notesSealed: null,
    });
    expect(updated?.label).toBe("Example 2");
    expect(updated?.hasNotes).toBe(false);
    expect(crypto.decrypt(updated!.secretSealed, browserCredentialRecordId(id))).toBe("new-secret");
  });

  it("is owner-scoped on update/delete", async () => {
    const owner = await user();
    const other = await user();
    const id = newId();
    await browserCredentialsRepo.create(db, {
      id,
      userId: owner,
      label: "Mine",
      site: "example.test",
      username: "",
      secretKind: "token",
      secretSealed: crypto.encrypt("tok", browserCredentialRecordId(id)),
    });

    expect(await browserCredentialsRepo.update(db, other, id, { label: "Hijacked" })).toBeNull();
    expect(await browserCredentialsRepo.remove(db, other, id)).toBe(false);
    expect((await browserCredentialsRepo.get(db, owner, id))?.label).toBe("Mine");
    expect(await browserCredentialsRepo.remove(db, owner, id)).toBe(true);
    expect(await browserCredentialsRepo.get(db, owner, id)).toBeNull();
  });

  it("enforces UNIQUE(user_id, label)", async () => {
    const uid = await user();
    const insert = (id: string) =>
      browserCredentialsRepo.create(db, {
        id,
        userId: uid,
        label: "Duplicate",
        site: "example.test",
        username: "",
        secretKind: "password",
        secretSealed: crypto.encrypt("x", browserCredentialRecordId(id)),
      });

    await insert(newId());
    await expect(insert(newId())).rejects.toSatisfy((err: unknown) => {
      let current: unknown = err;
      for (let depth = 0; depth < 4 && current != null; depth++) {
        if ((current as { code?: unknown }).code === "23505") return true;
        current = (current as { cause?: unknown }).cause;
      }
      return false;
    });
    expect(await browserCredentialsRepo.count(db, uid)).toBe(1);
  });
});
