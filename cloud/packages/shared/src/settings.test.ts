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
  it("defaults: push on, no BYOK routing", () => {
    expect(DEFAULT_ACCOUNT_SETTINGS).toEqual({ notificationsEnabled: true, byokDefault: null });
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
