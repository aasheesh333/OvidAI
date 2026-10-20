import { describe, expect, it } from "vitest";
import {
  CLOUD_PRESET_IDS,
  DEFAULT_USER_PREFERENCES,
  MAX_PROJECT_REFS,
  MAX_SESSION_REFS,
  sendMessageBodySchema,
  userPreferencesPatchSchema,
  userPreferencesSchema,
} from "./rest.js";

const UUID = "6f9619ff-8b86-d011-b42d-00cf4fc964ff";

describe("Wave 1a send-body settings", () => {
  it("accepts model, mode, planMode, presetId, sessionRefs and projectRefs", () => {
    const body = {
      content: "hi",
      model: "glm-5.3 · high",
      mode: "safe",
      planMode: true,
      presetId: "code",
      sessionRefs: [UUID],
      projectRefs: [UUID],
    };
    expect(sendMessageBodySchema.parse(body)).toEqual(body);
    expect(sendMessageBodySchema.parse({ content: "hi", model: "auto" }).model).toBe("auto");
  });

  it("rejects malformed settings", () => {
    expect(() => sendMessageBodySchema.parse({ content: "hi", model: "" })).toThrow();
    expect(() => sendMessageBodySchema.parse({ content: "hi", model: "x".repeat(161) })).toThrow();
    expect(() => sendMessageBodySchema.parse({ content: "hi", model: "a\nb" })).toThrow();
    expect(() => sendMessageBodySchema.parse({ content: "hi", mode: "control" })).toThrow();
    expect(() => sendMessageBodySchema.parse({ content: "hi", planMode: "yes" })).toThrow();
    expect(() => sendMessageBodySchema.parse({ content: "hi", presetId: "" })).toThrow();
    expect(() => sendMessageBodySchema.parse({ content: "hi", sessionRefs: ["nope"] })).toThrow();
    expect(() => sendMessageBodySchema.parse({ content: "hi", projectRefs: ["nope"] })).toThrow();
    expect(() =>
      sendMessageBodySchema.parse({
        content: "hi",
        sessionRefs: Array.from({ length: MAX_SESSION_REFS + 1 }, () => UUID),
      }),
    ).toThrow();
    expect(() =>
      sendMessageBodySchema.parse({
        content: "hi",
        projectRefs: Array.from({ length: MAX_PROJECT_REFS + 1 }, () => UUID),
      }),
    ).toThrow();
  });

  it("exports the built-in preset ids", () => {
    expect([...CLOUD_PRESET_IDS]).toEqual(["standard", "minimal", "studio", "code", "plan"]);
  });
});

describe("user preferences", () => {
  it("defaults keep memory on and cross-session sharing off", () => {
    expect(DEFAULT_USER_PREFERENCES).toEqual({ memoryEnabled: true, shareSessionMemory: false });
    expect(userPreferencesSchema.parse(DEFAULT_USER_PREFERENCES)).toEqual(DEFAULT_USER_PREFERENCES);
  });

  it("patch is strict and needs at least one field", () => {
    expect(userPreferencesPatchSchema.parse({ memoryEnabled: false })).toEqual({ memoryEnabled: false });
    expect(() => userPreferencesPatchSchema.parse({})).toThrow();
    expect(() => userPreferencesPatchSchema.parse({ memoryEnabled: "no" })).toThrow();
    expect(() => userPreferencesPatchSchema.parse({ memoryEnabled: true, other: 1 })).toThrow();
  });
});
