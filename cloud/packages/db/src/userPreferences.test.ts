import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { newId, userPreferences, users as usersRepo } from "./repos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("userPreferences repo (Wave 1a SE-005)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  it("returns defaults for an unknown user and for a user with no stored prefs", async () => {
    expect(await userPreferences.get(db, newId())).toEqual({
      memoryEnabled: true,
      shareSessionMemory: false,
    });
    const uid = newId();
    await usersRepo.ensure(db, uid, null);
    expect(await userPreferences.get(db, uid)).toEqual({
      memoryEnabled: true,
      shareSessionMemory: false,
    });
  });

  it("patch merges partial updates, provisions the user row and returns the full prefs", async () => {
    const uid = newId();
    expect(await userPreferences.patch(db, uid, { memoryEnabled: false })).toEqual({
      memoryEnabled: false,
      shareSessionMemory: false,
    });
    expect(await userPreferences.patch(db, uid, { shareSessionMemory: true })).toEqual({
      memoryEnabled: false,
      shareSessionMemory: true,
    });
    expect(await userPreferences.get(db, uid)).toEqual({
      memoryEnabled: false,
      shareSessionMemory: true,
    });
  });
});
