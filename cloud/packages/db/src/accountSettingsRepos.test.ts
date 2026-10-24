import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { newId, userPreferences } from "./repos.js";
import { accountSettings, customPresets } from "./accountSettingsRepos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const DEFAULT_NOTIFICATION_PREFERENCES = {
  agentUpdates: { enabled: true, sound: "chime" },
  schedulerResults: { enabled: true, sound: "chime" },
  backgroundStatus: { enabled: true, sound: "silent" },
  quietHours: {
    enabled: false,
    startMinutes: 22 * 60,
    endMinutes: 8 * 60,
    utcOffsetMinutes: 0,
  },
} as const;

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
    expect(await accountSettings.get(db, uid)).toEqual({
      notificationsEnabled: true,
      notificationPreferences: DEFAULT_NOTIFICATION_PREFERENCES,
      byokDefault: null,
    });
    expect(await customPresets.list(db, uid)).toEqual([]);
  });

  it("patches merge without clobbering the memory switches (and vice versa)", async () => {
    const uid = `u-${newId()}`;
    await userPreferences.patch(db, uid, { memoryEnabled: false });
    const keyId = newId();
    expect(
      await accountSettings.patch(db, uid, { notificationsEnabled: false, byokDefault: { keyId, model: "gpt-4.1" } }),
    ).toEqual({
      notificationsEnabled: false,
      notificationPreferences: DEFAULT_NOTIFICATION_PREFERENCES,
      byokDefault: { keyId, model: "gpt-4.1" },
    });
    await customPresets.upsert(db, uid, {
      id: "custom-safe",
      label: "Safe",
      description: "",
      deniedTools: ["run_shell"],
      model: null,
      temperature: 0.2,
    });
    await userPreferences.patch(db, uid, { shareSessionMemory: true });

    expect(await userPreferences.get(db, uid)).toEqual({
      memoryEnabled: false,
      shareSessionMemory: true,
      showReasoning: true,
    });
    expect(await accountSettings.get(db, uid)).toEqual({
      notificationsEnabled: false,
      notificationPreferences: DEFAULT_NOTIFICATION_PREFERENCES,
      byokDefault: { keyId, model: "gpt-4.1" },
    });
    expect((await customPresets.get(db, uid, "custom-safe"))?.deniedTools).toEqual(["run_shell"]);
  });

  it("merges channel preferences independently and forces background status silent", async () => {
    const uid = `u-${newId()}`;
    const first = await accountSettings.patch(db, uid, {
      notificationPreferences: {
        agentUpdates: { enabled: false, sound: "system" },
        backgroundStatus: { sound: "chime" },
        quietHours: {
          enabled: true,
          startMinutes: 21 * 60 + 30,
          endMinutes: 7 * 60 + 15,
          utcOffsetMinutes: -300,
        },
      },
    });
    expect(first.notificationPreferences).toEqual({
      agentUpdates: { enabled: false, sound: "system" },
      schedulerResults: { enabled: true, sound: "chime" },
      backgroundStatus: { enabled: true, sound: "silent" },
      quietHours: {
        enabled: true,
        startMinutes: 21 * 60 + 30,
        endMinutes: 7 * 60 + 15,
        utcOffsetMinutes: -300,
      },
    });

    const second = await accountSettings.patch(db, uid, {
      notificationPreferences: { schedulerResults: { enabled: false } },
    });
    expect(second.notificationPreferences).toEqual({
      agentUpdates: { enabled: false, sound: "system" },
      schedulerResults: { enabled: false, sound: "chime" },
      backgroundStatus: { enabled: true, sound: "silent" },
      quietHours: {
        enabled: true,
        startMinutes: 21 * 60 + 30,
        endMinutes: 7 * 60 + 15,
        utcOffsetMinutes: -300,
      },
    });
    expect(second.notificationsEnabled).toBe(true);
    expect(second.byokDefault).toBeNull();
  });

  it("preserves independent channel patches from two overlapping database connections", async () => {
    const uid = `u-${newId()}`;
    await userPreferences.patch(db, uid, { memoryEnabled: false });
    await accountSettings.patch(db, uid, {
      notificationPreferences: { agentUpdates: { sound: "system" } },
    });

    const agentDb = createDb(TEST_DATABASE_URL!, { max: 1 });
    const schedulerDb = createDb(TEST_DATABASE_URL!, { max: 1 });
    const controlDb = createDb(TEST_DATABASE_URL!, { max: 1 });
    const id = newId().replaceAll("-", "");
    const functionName = `ovid_test_delay_${id}`;
    const triggerName = `ovid_test_delay_trigger_${id}`;
    const agentName = `ovid-task2-agent-${id}`;
    const schedulerName = `ovid-task2-scheduler-${id}`;
    const lockKey = -parseInt(id.slice(0, 8), 16);
    let releaseLock = false;
    let agentPatch: Promise<unknown> | undefined;
    let schedulerPatch: Promise<unknown> | undefined;

    const waitFor = async (condition: () => Promise<boolean>): Promise<void> => {
      const deadline = Date.now() + 10_000;
      while (!(await condition())) {
        if (Date.now() >= deadline) throw new Error("timed out waiting for concurrent patch barrier");
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    };

    try {
      // A test-only BEFORE UPDATE trigger holds the agent writer at its update
      // boundary. With the legacy read/modify/write path, this guarantees both
      // patches read the same old value before either write completes.
      await controlDb.$client.unsafe(
        `CREATE FUNCTION "${functionName}"() RETURNS trigger LANGUAGE plpgsql AS $fn$
         BEGIN
           IF current_setting('ovid.task2_delay_notification_patch', true) = 'on' THEN
             PERFORM pg_advisory_xact_lock(${lockKey});
           END IF;
           RETURN NEW;
         END;
         $fn$`,
      );
      await controlDb.$client.unsafe(
        `CREATE TRIGGER "${triggerName}" BEFORE UPDATE ON users
         FOR EACH ROW EXECUTE FUNCTION "${functionName}"()`,
      );
      await controlDb.$client.unsafe("SELECT pg_advisory_lock($1)", [lockKey]);
      releaseLock = true;
      await agentDb.$client.unsafe(
        "SELECT set_config('application_name', $1, false), set_config('ovid.task2_delay_notification_patch', 'on', false)",
        [agentName],
      );
      await schedulerDb.$client.unsafe("SELECT set_config('application_name', $1, false)", [schedulerName]);

      agentPatch = accountSettings.patch(agentDb, uid, {
        notificationPreferences: { agentUpdates: { enabled: false } },
      });
      await waitFor(async () => {
        const rows = await controlDb.$client.unsafe(
          `SELECT 1 FROM pg_stat_activity
           WHERE application_name = $1 AND wait_event_type = 'Lock' LIMIT 1`,
          [agentName],
        );
        return rows.length === 1;
      });

      let schedulerSettled = false;
      schedulerPatch = accountSettings.patch(schedulerDb, uid, {
        notificationPreferences: { schedulerResults: { enabled: false } },
      });
      void schedulerPatch.then(
        () => { schedulerSettled = true; },
        () => { schedulerSettled = true; },
      );
      // Reaching the INSERT proves the scheduler crossed the same barrier. If
      // it commits before polling observes it, schedulerSettled proves that too.
      await waitFor(async () => {
        if (schedulerSettled) return true;
        const rows = await controlDb.$client.unsafe(
          `SELECT 1 FROM pg_stat_activity
           WHERE application_name = $1 AND position('on conflict' in query) > 0 LIMIT 1`,
          [schedulerName],
        );
        return rows.length === 1;
      });
      await controlDb.$client.unsafe("SELECT pg_advisory_unlock($1)", [lockKey]);
      releaseLock = false;
      await Promise.all([agentPatch, schedulerPatch]);

      const final = await accountSettings.get(db, uid);
      expect(final.notificationPreferences).toEqual({
        agentUpdates: { enabled: false, sound: "system" },
        schedulerResults: { enabled: false, sound: "chime" },
        backgroundStatus: { enabled: true, sound: "silent" },
        quietHours: DEFAULT_NOTIFICATION_PREFERENCES.quietHours,
      });
      expect(await userPreferences.get(db, uid)).toMatchObject({ memoryEnabled: false });
    } finally {
      if (releaseLock) {
        await controlDb.$client.unsafe("SELECT pg_advisory_unlock($1)", [lockKey]).catch(() => {});
      }
      await Promise.allSettled([agentPatch, schedulerPatch]);
      await controlDb.$client.unsafe(`DROP TRIGGER IF EXISTS "${triggerName}" ON users`).catch(() => {});
      await controlDb.$client.unsafe(`DROP FUNCTION IF EXISTS "${functionName}"()`).catch(() => {});
      await Promise.all([
        agentDb.$client.end({ timeout: 5 }),
        schedulerDb.$client.end({ timeout: 5 }),
        controlDb.$client.end({ timeout: 5 }),
      ]);
    }
  }, 30_000);

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
