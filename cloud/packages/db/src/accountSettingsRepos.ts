import { eq, sql } from "drizzle-orm";
import type { AccountSettings, ByokDefault, CustomPreset } from "@ovid/shared";
import type { Db } from "./client.js";
import { users as usersTable } from "./schema.js";

/**
 * Wave 4 (Settings truthfulness): account-level settings the server enforces,
 * stored beside the Wave 1a memory switches in `users.preferences` (jsonb) —
 * no migration. Each writer merges ONLY its own top-level keys with `||`, so
 * the memory switches, these settings and the custom presets never clobber
 * each other.
 *
 * Keys: notificationsEnabled (bool, default true), byokDefault
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

/** Merge top-level keys into users.preferences, provisioning the row. */
async function mergePreferences(
  db: Db,
  uid: string,
  patch: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const [row] = await db
    .insert(usersTable)
    .values({ uid, preferences: patch })
    .onConflictDoUpdate({
      target: usersTable.uid,
      set: {
        preferences: sql`COALESCE(${usersTable.preferences}, '{}'::jsonb) || ${JSON.stringify(patch)}::jsonb`,
      },
    })
    .returning({ preferences: usersTable.preferences });
  return readJson(row?.preferences);
}

function settingsFrom(o: Record<string, unknown>): AccountSettings {
  return {
    notificationsEnabled: typeof o.notificationsEnabled === "boolean" ? o.notificationsEnabled : true,
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
    patch: { notificationsEnabled?: boolean; byokDefault?: ByokDefault | null },
  ): Promise<AccountSettings> {
    const clean: Record<string, unknown> = {};
    if (typeof patch.notificationsEnabled === "boolean") {
      clean.notificationsEnabled = patch.notificationsEnabled;
    }
    if (patch.byokDefault !== undefined) {
      clean.byokDefault =
        patch.byokDefault === null
          ? null
          : { keyId: patch.byokDefault.keyId, model: patch.byokDefault.model };
    }
    if (Object.keys(clean).length === 0) return accountSettings.get(db, uid);
    return settingsFrom(await mergePreferences(db, uid, clean));
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
