import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { newId, userPreferences } from "./repos.js";
import { accountSettings, customPresets } from "./accountSettingsRepos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("accountSettings + customPresets repos (Wave 4)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  it("defaults for an unknown user: push on, no BYOK routing, no presets", async () => {
    const uid = `u-${newId()}`;
    expect(await accountSettings.get(db, uid)).toEqual({ notificationsEnabled: true, byokDefault: null });
    expect(await customPresets.list(db, uid)).toEqual([]);
  });

  it("patches merge without clobbering the memory switches (and vice versa)", async () => {
    const uid = `u-${newId()}`;
    await userPreferences.patch(db, uid, { memoryEnabled: false });
    const keyId = newId();
    expect(
      await accountSettings.patch(db, uid, { notificationsEnabled: false, byokDefault: { keyId, model: "gpt-4.1" } }),
    ).toEqual({ notificationsEnabled: false, byokDefault: { keyId, model: "gpt-4.1" } });
    await customPresets.upsert(db, uid, {
      id: "custom-safe",
      label: "Safe",
      description: "",
      deniedTools: ["run_shell"],
      model: null,
      temperature: 0.2,
    });
    await userPreferences.patch(db, uid, { shareSessionMemory: true });

    expect(await userPreferences.get(db, uid)).toEqual({ memoryEnabled: false, shareSessionMemory: true });
    expect(await accountSettings.get(db, uid)).toEqual({
      notificationsEnabled: false,
      byokDefault: { keyId, model: "gpt-4.1" },
    });
    expect((await customPresets.get(db, uid, "custom-safe"))?.deniedTools).toEqual(["run_shell"]);
  });

  it("clearByokDefaultIfKey only clears a matching key", async () => {
    const uid = `u-${newId()}`;
    const keyId = newId();
    await accountSettings.patch(db, uid, { byokDefault: { keyId, model: "m" } });
    await accountSettings.clearByokDefaultIfKey(db, uid, newId());
    expect((await accountSettings.get(db, uid)).byokDefault?.keyId).toBe(keyId);
    await accountSettings.clearByokDefaultIfKey(db, uid, keyId);
    expect((await accountSettings.get(db, uid)).byokDefault).toBeNull();
  });

  it("custom presets upsert by id and remove", async () => {
    const uid = `u-${newId()}`;
    const base = { description: "", deniedTools: [], model: null, temperature: null };
    await customPresets.upsert(db, uid, { id: "custom-a", label: "A", ...base });
    await customPresets.upsert(db, uid, { id: "custom-b", label: "B", ...base });
    await customPresets.upsert(db, uid, { id: "custom-a", label: "A2", ...base });
    expect((await customPresets.list(db, uid)).map((p) => p.label)).toEqual(["A2", "B"]);
    expect(await customPresets.remove(db, uid, "custom-a")).toBe(true);
    expect(await customPresets.remove(db, uid, "custom-a")).toBe(false);
    expect((await customPresets.list(db, uid)).map((p) => p.id)).toEqual(["custom-b"]);
  });
});
