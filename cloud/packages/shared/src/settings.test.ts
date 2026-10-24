import { describe, expect, it } from "vitest";
import {
  accountSettingsPatchSchema,
  CUSTOM_PRESET_ID_RE,
  customPresetBodySchema,
  DEFAULT_ACCOUNT_SETTINGS,
  GATEABLE_TOOL_NAMES,
  memoryPutBodySchema,
  PRESET_TOOL_GROUPS,
} from "./settings.js";

const UUID = "0190a6b2-7c4e-7a10-8000-000000000001";

describe("account settings (Wave 4)", () => {
  it("defaults preserve master-on/channel-on/chime and add silent background status", () => {
    expect(DEFAULT_ACCOUNT_SETTINGS).toEqual({
      notificationsEnabled: true,
      notificationPreferences: {
        agentUpdates: { enabled: true, sound: "chime" },
        schedulerResults: { enabled: true, sound: "chime" },
        backgroundStatus: { enabled: true, sound: "silent" },
        quietHours: {
          enabled: false,
          startMinutes: 22 * 60,
          endMinutes: 8 * 60,
          utcOffsetMinutes: 0,
        },
      },
      byokDefault: null,
    });
  });

  it("patch is strict, needs a field and validates the BYOK default", () => {
    expect(accountSettingsPatchSchema.parse({ notificationsEnabled: false })).toEqual({
      notificationsEnabled: false,
    });
    expect(accountSettingsPatchSchema.parse({ byokDefault: null })).toEqual({ byokDefault: null });
    expect(
      accountSettingsPatchSchema.parse({ byokDefault: { keyId: UUID, model: " gpt-4.1 " } }),
    ).toEqual({ byokDefault: { keyId: UUID, model: "gpt-4.1" } });
    expect(() => accountSettingsPatchSchema.parse({})).toThrow();
    expect(() => accountSettingsPatchSchema.parse({ other: 1, notificationsEnabled: true })).toThrow();
    expect(() => accountSettingsPatchSchema.parse({ byokDefault: { keyId: "x", model: "m" } })).toThrow();
    expect(() => accountSettingsPatchSchema.parse({ byokDefault: { keyId: UUID, model: "" } })).toThrow();
  });

  it("accepts independent channel and quiet-hours patches", () => {
    const patch = {
      notificationPreferences: {
        agentUpdates: { enabled: false },
        schedulerResults: { sound: "system" },
        backgroundStatus: { enabled: false },
        quietHours: {
          enabled: true,
          startMinutes: 21 * 60 + 30,
          endMinutes: 7 * 60 + 15,
          utcOffsetMinutes: -300,
        },
      },
    };
    expect(accountSettingsPatchSchema.parse(patch)).toEqual(patch);
  });

  it("rejects malformed channel sounds, quiet-hours times, offsets, and unknown keys", () => {
    expect(() => accountSettingsPatchSchema.parse({
      notificationPreferences: { agentUpdates: { sound: "loud" } },
    })).toThrow();
    expect(() => accountSettingsPatchSchema.parse({
      notificationPreferences: { quietHours: { startMinutes: 1440 } },
    })).toThrow();
    expect(() => accountSettingsPatchSchema.parse({
      notificationPreferences: { quietHours: { endMinutes: 1.5 } },
    })).toThrow();
    expect(() => accountSettingsPatchSchema.parse({
      notificationPreferences: { quietHours: { utcOffsetMinutes: 841 } },
    })).toThrow();
    expect(() => accountSettingsPatchSchema.parse({
      notificationPreferences: { otherChannel: { enabled: false } },
    })).toThrow();
  });
});

describe("custom presets (Wave 4 SE-007)", () => {
  it("ids are custom- prefixed slugs", () => {
    expect(CUSTOM_PRESET_ID_RE.test("custom-safe-1")).toBe(true);
    expect(CUSTOM_PRESET_ID_RE.test("standard")).toBe(false);
    expect(CUSTOM_PRESET_ID_RE.test("custom-")).toBe(false);
    expect(CUSTOM_PRESET_ID_RE.test("custom-UPPER")).toBe(false);
  });

  it("every group tool is gateable and the body only accepts gateable tools", () => {
    for (const g of PRESET_TOOL_GROUPS) for (const t of g.tools) expect(GATEABLE_TOOL_NAMES.has(t)).toBe(true);
    const ok = customPresetBodySchema.parse({ label: "Safe", deniedTools: ["run_shell"] });
    expect(ok).toEqual({
      label: "Safe",
      description: "",
      deniedTools: ["run_shell"],
      model: null,
      temperature: null,
    });
    expect(() => customPresetBodySchema.parse({ label: "x", deniedTools: ["rm_rf"] })).toThrow();
    expect(() => customPresetBodySchema.parse({ label: "x", temperature: 3 })).toThrow();
    expect(() => customPresetBodySchema.parse({ label: "" })).toThrow();
  });

  it("memory writes are capped at 32 KiB", () => {
    expect(memoryPutBodySchema.parse({ content: "hi" })).toEqual({ content: "hi" });
    expect(() => memoryPutBodySchema.parse({ content: "x".repeat(32 * 1024 + 1) })).toThrow();
  });
});
