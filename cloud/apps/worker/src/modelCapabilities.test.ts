import { describe, expect, it, vi } from "vitest";
import {
  createModelCatalogReader,
  imageMimeTypeFor,
  modelVisionSupport,
  visionRefusalMessage,
} from "./modelCapabilities.js";

/**
 * Vision capability detection (owner directive 2026-10-18).
 *
 * The dangerous direction is a FALSE POSITIVE: telling the worker a text-only
 * model can see makes it ship an image the provider rejects (or silently
 * drops) and the user pays for a broken run. Every test here is written with
 * that asymmetry in mind — unknown models must resolve to "no".
 */

describe("modelVisionSupport", () => {
  it("trusts the operator's catalog first, in both directions", () => {
    const catalog = [
      { model_name: "my-custom-vlm", model_info: { supports_vision: true } },
      { model_name: "gpt-4o", model_info: { supports_vision: false } },
    ];
    expect(modelVisionSupport("my-custom-vlm", catalog)).toEqual({ supports: true, basis: "catalog" });
    // The catalog OUTRANKS the family list: an operator who marks gpt-4o as
    // text-only (a proxy shim, a text-only variant) is believed.
    expect(modelVisionSupport("gpt-4o", catalog)).toEqual({ supports: false, basis: "catalog" });
  });

  it("falls through when the catalog has no opinion (supports_vision null/absent)", () => {
    const catalog = [{ model_name: "gemini-3.7-flash", model_info: { supports_vision: null } }];
    expect(modelVisionSupport("gemini-3.7-flash", catalog)).toEqual({ supports: true, basis: "family" });
  });

  it("matches documented vision families, including aggregator prefixes", () => {
    for (const model of [
      "gpt-4o",
      "openai/gpt-4o-mini",
      "azure/gpt-4.1",
      "claude-4-sonnet",
      "anthropic/claude-5-opus",
      "gemini-3.1-pro",
      "qwen2.5-vl-72b",
      "llava-1.6",
      "grok-4",
    ]) {
      expect(modelVisionSupport(model, null).supports, model).toBe(true);
    }
  });

  it("refuses text-only models even when their name resembles a vision family", () => {
    // These are the models this deployment actually routes; none accepts
    // images today. `deepseek-v4.1-flash` and `glm-5.3-flash` are pinned in
    // the override list precisely so a broader family entry cannot catch them.
    for (const model of [
      "deepseek-v4.1-flash",
      "deepseek-chat",
      "glm-5.3-flash",
      "glm-5.3",
      "minimax-m3",
      "kimi-k3",
      "qwen3.8-max",
    ]) {
      expect(modelVisionSupport(model, null).supports, model).toBe(false);
    }
  });

  it("an UNKNOWN model is refused, never guessed (the asymmetry that matters)", () => {
    const decision = modelVisionSupport("some-new-vendor/quantum-9", null);
    expect(decision).toEqual({ supports: false, basis: "unknown" });
  });

  it("an empty model name is refused", () => {
    expect(modelVisionSupport("", null)).toEqual({ supports: false, basis: "unknown" });
    expect(modelVisionSupport("   ", null)).toEqual({ supports: false, basis: "unknown" });
  });

  it("is case-insensitive and tolerates surrounding whitespace", () => {
    expect(modelVisionSupport("  GPT-4O  ", null).supports).toBe(true);
    expect(modelVisionSupport("DeepSeek-V4.1-Flash", null).supports).toBe(false);
  });
});

describe("visionRefusalMessage", () => {
  it("names the model and the two ways out", () => {
    const message = visionRefusalMessage("my-text-model");
    expect(message).toContain("'my-text-model'");
    expect(message).toContain("does not support vision/image inputs");
    expect(message).toContain("switch to a vision-capable model");
    expect(message).toContain("remove the image context");
  });
});

describe("imageMimeTypeFor", () => {
  it("maps the four forwarded image types", () => {
    expect(imageMimeTypeFor("shot.PNG")).toBe("image/png");
    expect(imageMimeTypeFor("photo.jpeg")).toBe("image/jpeg");
    expect(imageMimeTypeFor("photo.jpg")).toBe("image/jpeg");
    expect(imageMimeTypeFor("frame.webp")).toBe("image/webp");
    expect(imageMimeTypeFor("anim.gif")).toBe("image/gif");
  });

  it("is not an image for everything else (no guessing)", () => {
    for (const name of ["notes.txt", "archive.zip", "model.bin", "noextension", "trailing."]) {
      expect(imageMimeTypeFor(name), name).toBeNull();
    }
  });

  it("uses the LAST extension (a name may contain dots)", () => {
    expect(imageMimeTypeFor("screenshot.2026.10.18.png")).toBe("image/png");
    expect(imageMimeTypeFor("shot.png.exe")).toBeNull();
  });
});

describe("createModelCatalogReader", () => {
  it("caches within the TTL and refetches after it", async () => {
    let now = 1_000;
    const fetchImpl = vi.fn(async () =>
      new Response(JSON.stringify({ data: [{ model_name: "m", model_info: { supports_vision: true } }] }), {
        status: 200,
      }),
    );
    const read = createModelCatalogReader({
      baseUrl: "http://litellm.invalid",
      masterKey: "sk-x",
      ttlMs: 1000,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      now: () => now,
    });

    await read();
    await read();
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    now += 1001;
    await read();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("returns null on a non-2xx or a malformed body, and never throws", async () => {
    const bad = createModelCatalogReader({
      baseUrl: "http://litellm.invalid",
      masterKey: "sk-x",
      fetchImpl: (async () => new Response("nope", { status: 500 })) as unknown as typeof fetch,
    });
    await expect(bad()).resolves.toBeNull();

    const malformed = createModelCatalogReader({
      baseUrl: "http://litellm.invalid",
      masterKey: "sk-x",
      fetchImpl: (async () => new Response(JSON.stringify({ data: "not-an-array" }), { status: 200 })) as unknown as typeof fetch,
    });
    await expect(malformed()).resolves.toBeNull();

    const throws = createModelCatalogReader({
      baseUrl: "http://litellm.invalid",
      masterKey: "sk-x",
      fetchImpl: (async () => {
        throw new Error("ECONNREFUSED");
      }) as unknown as typeof fetch,
    });
    await expect(throws()).resolves.toBeNull();
  });

  it("sends the master key and hits /model/info", async () => {
    const seen: Array<{ url: string; auth: string | null }> = [];
    const read = createModelCatalogReader({
      baseUrl: "http://litellm.invalid/",
      masterKey: "sk-master",
      fetchImpl: (async (url: string, init?: RequestInit) => {
        seen.push({
          url: String(url),
          auth: (init?.headers as Record<string, string> | undefined)?.authorization ?? null,
        });
        return new Response(JSON.stringify({ data: [] }), { status: 200 });
      }) as unknown as typeof fetch,
    });

    await read();

    expect(seen).toEqual([{ url: "http://litellm.invalid/model/info", auth: "Bearer sk-master" }]);
  });
});
