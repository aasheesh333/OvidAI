import { eq, sql, type SQL } from "drizzle-orm";
import {
  DEFAULT_NOTIFICATION_PREFERENCES,
  type AccountSettings,
  type AccountSettingsPatch,
  type ByokDefault,
  type CustomPreset,
  type NotificationChannelPreference,
  type NotificationPreferences,
  type NotificationPreferencesPatch,
  type NotificationSound,
} from "@ovid/shared";
import type { Db } from "./client.js";
import { users as usersTable } from "./schema.js";

/**
 * Wave 4 (Settings truthfulness): account-level settings the server enforces,
 * stored beside the Wave 1a memory switches in `users.preferences` (jsonb) —
 * no migration. Each writer merges ONLY its own top-level keys with `||`, so
 * the memory switches, these settings and the custom presets never clobber
 * each other.
 *
 * Keys: notificationsEnabled (bool, default true), notificationPreferences
 * (per-channel switches/sounds plus quiet hours), byokDefault
 * ({keyId, model} | null), customPresets (CustomPreset[]).
 */

function readJson(raw: unknown): Record<string, unknown> {
  return raw !== null && typeof raw === "object" && !Array.isArray(raw)
    ? (raw as Record<string, unknown>)
    : {};
}

function byokDefaultFrom(raw: unknown): ByokDefault | null {
  if (raw === null || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  return typeof o.keyId === "string" && o.keyId !== "" && typeof o.model === "string" && o.model !== ""
    ? { keyId: o.keyId, model: o.model }
    : null;
}

function notificationChannelPreferenceFrom(
  raw: unknown,
  fallback: NotificationChannelPreference,
  alwaysSilent = false,
): NotificationChannelPreference {
  const o = readJson(raw);
  const sound: NotificationSound =
    o.sound === "chime" || o.sound === "system" || o.sound === "silent"
      ? o.sound
      : fallback.sound;
  return {
    enabled: typeof o.enabled === "boolean" ? o.enabled : fallback.enabled,
    sound: alwaysSilent ? "silent" : sound,
  };
}

function minuteInRange(raw: unknown, fallback: number, min: number, max: number): number {
  return typeof raw === "number" && Number.isInteger(raw) && raw >= min && raw <= max
    ? raw
    : fallback;
}

function notificationPreferencesFrom(raw: unknown): NotificationPreferences {
  const o = readJson(raw);
  const quiet = readJson(o.quietHours);
  const defaults = DEFAULT_NOTIFICATION_PREFERENCES;
  return {
    agentUpdates: notificationChannelPreferenceFrom(o.agentUpdates, defaults.agentUpdates),
    schedulerResults: notificationChannelPreferenceFrom(o.schedulerResults, defaults.schedulerResults),
    backgroundStatus: notificationChannelPreferenceFrom(
      o.backgroundStatus,
      defaults.backgroundStatus,
      true,
    ),
    quietHours: {
      enabled: typeof quiet.enabled === "boolean" ? quiet.enabled : defaults.quietHours.enabled,
      startMinutes: minuteInRange(quiet.startMinutes, defaults.quietHours.startMinutes, 0, 1439),
      endMinutes: minuteInRange(quiet.endMinutes, defaults.quietHours.endMinutes, 0, 1439),
      utcOffsetMinutes: minuteInRange(
        quiet.utcOffsetMinutes,
        defaults.quietHours.utcOffsetMinutes,
        -14 * 60,
        14 * 60,
      ),
    },
  };
}

type ChannelPreferencePatch = { enabled?: boolean; sound?: NotificationSound };

function channelPreferencePatchFrom(update: ChannelPreferencePatch): ChannelPreferencePatch {
  const clean: ChannelPreferencePatch = {};
  if (update.enabled !== undefined) clean.enabled = update.enabled;
  if (update.sound !== undefined) clean.sound = update.sound;
  return clean;
}

/** Keep only supplied leaves so PostgreSQL can merge them without a stale read. */
function notificationPreferencesPatchFrom(
  patch: NotificationPreferencesPatch | undefined,
): NotificationPreferencesPatch | undefined {
  if (patch === undefined) return undefined;
  const clean: NotificationPreferencesPatch = {};
  if (patch.agentUpdates !== undefined) {
    clean.agentUpdates = channelPreferencePatchFrom(patch.agentUpdates);
  }
  if (patch.schedulerResults !== undefined) {
    clean.schedulerResults = channelPreferencePatchFrom(patch.schedulerResults);
  }
  if (patch.backgroundStatus !== undefined) {
    clean.backgroundStatus = {
      ...channelPreferencePatchFrom(patch.backgroundStatus),
      sound: "silent",
    };
  }
  if (patch.quietHours !== undefined) {
    const quietHours: NonNullable<NotificationPreferencesPatch["quietHours"]> = {};
    if (patch.quietHours.enabled !== undefined) quietHours.enabled = patch.quietHours.enabled;
    if (patch.quietHours.startMinutes !== undefined) quietHours.startMinutes = patch.quietHours.startMinutes;
    if (patch.quietHours.endMinutes !== undefined) quietHours.endMinutes = patch.quietHours.endMinutes;
    if (patch.quietHours.utcOffsetMinutes !== undefined) {
      quietHours.utcOffsetMinutes = patch.quietHours.utcOffsetMinutes;
    }
    clean.quietHours = quietHours;
  }
  return clean;
}

function presetFrom(raw: unknown): CustomPreset | null {
  if (raw === null || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.id !== "string" || typeof o.label !== "string") return null;
  return {
    id: o.id,
    label: o.label,
    description: typeof o.description === "string" ? o.description : "",
    deniedTools: Array.isArray(o.deniedTools)
      ? o.deniedTools.filter((t): t is string => typeof t === "string")
      : [],
    model: typeof o.model === "string" && o.model !== "" ? o.model : null,
    temperature: typeof o.temperature === "number" ? o.temperature : null,
  };
}

async function readPreferences(db: Db, uid: string): Promise<Record<string, unknown>> {
  const [row] = await db
    .select({ preferences: usersTable.preferences })
    .from(usersTable)
    .where(eq(usersTable.uid, uid));
  return readJson(row?.preferences);
}

function mergeNestedPreference(base: SQL, key: string, patch: object): SQL {
  const path = `{notificationPreferences,${key}}`;
  return sql`jsonb_set(
    ${base},
    ${path}::text[],
    COALESCE((${base}) #> ${path}::text[], '{}'::jsonb) || ${JSON.stringify(patch)}::jsonb,
    true
  )`;
}

/**
 * Merge into users.preferences, provisioning the row. Notification leaves use
 * nested jsonb_set expressions against the row PostgreSQL actually updates;
 * concurrent patches therefore cannot restore values from a stale app read.
 */
async function mergePreferences(
  db: Db,
  uid: string,
  patch: Record<string, unknown>,
  notificationPatch?: NotificationPreferencesPatch,
): Promise<Record<string, unknown>> {
  const values = notificationPatch === undefined
    ? patch
    : { ...patch, notificationPreferences: notificationPatch };
  let merged = sql`COALESCE(${usersTable.preferences}, '{}'::jsonb) || ${JSON.stringify(patch)}::jsonb`;
  if (notificationPatch !== undefined) {
    // jsonb_set creates the final key but not missing intermediate objects.
    merged = sql`jsonb_set(
      ${merged},
      '{notificationPreferences}',
      COALESCE((${merged})->'notificationPreferences', '{}'::jsonb),
      true
    )`;
    for (const key of ["agentUpdates", "schedulerResults", "backgroundStatus", "quietHours"] as const) {
      const nestedPatch = notificationPatch[key];
      if (nestedPatch !== undefined) merged = mergeNestedPreference(merged, key, nestedPatch);
    }
  }
  const [row] = await db
    .insert(usersTable)
    .values({ uid, preferences: values })
    .onConflictDoUpdate({
      target: usersTable.uid,
      set: { preferences: merged },
    })
    .returning({ preferences: usersTable.preferences });
  return readJson(row?.preferences);
}

function settingsFrom(o: Record<string, unknown>): AccountSettings {
  return {
    notificationsEnabled: typeof o.notificationsEnabled === "boolean" ? o.notificationsEnabled : true,
    notificationPreferences: notificationPreferencesFrom(o.notificationPreferences),
    byokDefault: byokDefaultFrom(o.byokDefault),
  };
}

export const accountSettings = {
  /** Effective settings with defaults (push on, no BYOK routing). */
  async get(db: Db, uid: string): Promise<AccountSettings> {
    return settingsFrom(await readPreferences(db, uid));
  },

  async patch(
    db: Db,
    uid: string,
    patch: AccountSettingsPatch,
  ): Promise<AccountSettings> {
    const clean: Record<string, unknown> = {};
    if (typeof patch.notificationsEnabled === "boolean") {
      clean.notificationsEnabled = patch.notificationsEnabled;
    }
    const notificationPatch = notificationPreferencesPatchFrom(patch.notificationPreferences);
    if (patch.byokDefault !== undefined) {
      clean.byokDefault =
        patch.byokDefault === null
          ? null
          : { keyId: patch.byokDefault.keyId, model: patch.byokDefault.model };
    }
    if (Object.keys(clean).length === 0 && notificationPatch === undefined) {
      return accountSettings.get(db, uid);
    }
    return settingsFrom(await mergePreferences(db, uid, clean, notificationPatch));
  },

  /**
   * Clears byokDefault when it points at [keyId] (the key was deleted), so a
   * run never references a key that no longer exists.
   */
  async clearByokDefaultIfKey(db: Db, uid: string, keyId: string): Promise<void> {
    const current = await accountSettings.get(db, uid);
    if (current.byokDefault?.keyId === keyId) {
      await mergePreferences(db, uid, { byokDefault: null });
    }
  },
};

export const customPresets = {
  async list(db: Db, uid: string): Promise<CustomPreset[]> {
    const raw = (await readPreferences(db, uid)).customPresets;
    if (!Array.isArray(raw)) return [];
    return raw.map(presetFrom).filter((p): p is CustomPreset => p !== null);
  },

  async get(db: Db, uid: string, id: string): Promise<CustomPreset | null> {
    return (await customPresets.list(db, uid)).find((p) => p.id === id) ?? null;
  },

  /** Insert or replace [preset] by id; returns the full list. */
  async upsert(db: Db, uid: string, preset: CustomPreset): Promise<CustomPreset[]> {
    const list = await customPresets.list(db, uid);
    const next = list.some((p) => p.id === preset.id)
      ? list.map((p) => (p.id === preset.id ? preset : p))
      : [...list, preset];
    await mergePreferences(db, uid, { customPresets: next });
    return next;
  },

  /** Removes [id]; false when it did not exist. */
  async remove(db: Db, uid: string, id: string): Promise<boolean> {
    const list = await customPresets.list(db, uid);
    const next = list.filter((p) => p.id !== id);
    if (next.length === list.length) return false;
    await mergePreferences(db, uid, { customPresets: next });
    return true;
  },
};
