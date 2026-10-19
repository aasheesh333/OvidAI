import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { newId, sessions, userPreferences, users as usersRepo } from "./repos.js";

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

  it("sessions.findByTitles matches the caller's live sessions case-insensitively", async () => {
    const uid = newId();
    const other = newId();
    await usersRepo.ensure(db, uid, null);
    await usersRepo.ensure(db, other, null);
    const a = await sessions.create(db, uid, "Project Notes");
    const gone = await sessions.create(db, uid, "project notes");
    await sessions.softDelete(db, gone.id, uid);
    await sessions.create(db, other, "Project Notes");
    const found = await sessions.findByTitles(db, uid, ["  PROJECT notes ", "missing"]);
    expect(found).toEqual([{ id: a.id, title: "Project Notes" }]);
    expect(await sessions.findByTitles(db, uid, [])).toEqual([]);
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
