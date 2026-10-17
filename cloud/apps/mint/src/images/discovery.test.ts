import { describe, expect, it } from "vitest";
import type { MintEnv } from "../env.js";
import { imageDiscoveredFromModelInfo } from "../index.js";
import type { ModelInfoRow } from "../litellmAdmin.js";
import { createDirectEdit } from "./directEdit.js";

/**
 * T14 review MEDIUM regression: discovery must derive `edit_transport` solely
 * from `enabled_for()` (preserving only an explicit `"none"`). A stale
 * `litellm_params.edit_transport: "direct"` must never survive a missing key
 * or a non-allowlisted host, or the card would route to a call that can only
 * fail and retain the reservation.
 */

const BASE = "https://api.inferhub.dev/v1";

function envWith(images: Partial<MintEnv["images"]> = {}): MintEnv {
  return {
    images: {
      maxUpstreamCostUsd: null,
      inferhubApiKey: "sk-inferhub",
      directEditHosts: "api.inferhub.dev",
      editCostUsd: null,
      probeKey: null,
      probeMaxUsd: 0.5,
      probeDailyUsd: 5,
      probeTtlS: 604800,
      probeStaggerS: 30,
      probeMaxSizes: 4,
      ...images,
    },
  } as unknown as MintEnv;
}

function row(name: string, params: Record<string, unknown>): ModelInfoRow {
  return {
    model_name: name,
    model_info: { mode: "image_generation" },
    litellm_params: params,
  };
}

describe("image discovery edit_transport identity", () => {
  it("drops a stale direct marker when the key is absent", () => {
    const direct = createDirectEdit(envWith({ inferhubApiKey: "" }));
    const [found] = imageDiscoveredFromModelInfo(
      [
        row("cb/m", {
          model: "openai/cb/gpt-image-2",
          api_base: BASE,
          edit_transport: "direct",
        }),
      ],
      direct,
    );
    expect(found!.params.edit_transport).toBeUndefined();
  });

  it("drops a stale direct marker when the host is not allowlisted", () => {
    const direct = createDirectEdit(envWith());
    const [found] = imageDiscoveredFromModelInfo(
      [
        row("cb/m", {
          model: "openai/cb/gpt-image-2",
          api_base: "https://images.example.com/v1",
          edit_transport: "direct",
        }),
      ],
      direct,
    );
    expect(found!.params.edit_transport).toBeUndefined();
  });

  it("tags direct only when enabled_for() is true", () => {
    const direct = createDirectEdit(envWith());
    const [found] = imageDiscoveredFromModelInfo(
      [
        row("cb/m", {
          model: "openai/cb/gpt-image-2",
          api_base: BASE,
        }),
      ],
      direct,
    );
    expect(found!.params.edit_transport).toBe("direct");
    // Identity still carries only the non-secret fields.
    expect(found!.params).toEqual({
      model: "openai/cb/gpt-image-2",
      api_base: BASE,
      edit_transport: "direct",
    });
  });

  it("preserves an explicit none even when the transport is enabled", () => {
    const direct = createDirectEdit(envWith());
    const [found] = imageDiscoveredFromModelInfo(
      [
        row("cb/m", {
          model: "openai/cb/gpt-image-2",
          api_base: BASE,
          edit_transport: "none",
        }),
      ],
      direct,
    );
    expect(found!.params.edit_transport).toBe("none");
  });
});
