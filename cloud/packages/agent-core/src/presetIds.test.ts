import { describe, expect, it } from "vitest";
import { CLOUD_PRESET_IDS } from "@ovid/shared";

import { BUILT_IN_PRESETS } from "./presets.js";

describe("CLOUD_PRESET_IDS (Wave 1a)", () => {
  it("equals the built-in preset ids the gateway validates presetId against", () => {
    expect([...CLOUD_PRESET_IDS]).toEqual(BUILT_IN_PRESETS.map((p) => p.id));
  });
});
