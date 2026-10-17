import { describe, expect, it } from "vitest";
import {
  CARD_SCHEMA,
  DEFAULT_SIZE,
  OPERATIONS,
  PUBLIC_SCHEMA,
  assignCostTiers,
  cap,
  catalogHash,
  clone,
  defaultCard,
  deriveTags,
  finalize,
  fingerprint,
  legacyCard,
  maxInputs,
  mergeFacts,
  publicCard,
  ratioOf,
  slugFor,
  supports,
} from "./capabilities.js";
import { costMapLookup, providerModelsEntry, staticExtract } from "./extraction.js";

const PARAMS = { model: "openai/gpt-image-2", api_base: "https://secret-provider.example/v1" };
const COST_MAP = {
  "gpt-image-2": {
    mode: "image_generation",
    supported_endpoints: ["/v1/images/generations", "/v1/images/edits"],
    output_cost_per_image: 0.04,
  },
};

describe("static extraction (capabilities.py / extraction.py)", () => {
  it("model_info and cost map declare edit and cost", () => {
    const { facts, meta } = staticExtract(
      "cb/gpt-image-2",
      PARAMS,
      { mode: "image_generation" },
      COST_MAP,
    );
    expect(facts.operations?.generate?.supported).toBe(true);
    expect(facts.operations?.edit).toEqual({
      supported: true,
      source: "declared",
      confidence: 0.85,
    });
    expect(facts.measured_cost_usd).toBe(0.04);
    expect(meta.sources).toContain("litellm.supported_endpoints");
  });

  it("endpoints without edits mark edit unsupported", () => {
    const { facts } = staticExtract(
      "x/some-model",
      { model: "some-model" },
      { mode: "image_generation", supported_endpoints: ["/v1/images/generations"] },
    );
    expect(facts.operations?.edit?.supported).toBe(false);
  });

  it("an unknown model gets no guessed edit", () => {
    const { facts } = staticExtract("mystery", {}, { mode: "image_generation" });
    const card = mergeFacts(defaultCard("mystery"), facts);
    expect(supports(card, "edit")).toBe(false);
    expect(card.sizes.native).toEqual([DEFAULT_SIZE]);
  });

  it("reads OpenRouter-style architecture", () => {
    const entry = providerModelsEntry(
      {
        data: [
          {
            id: "vendor/pic",
            architecture: {
              input_modalities: ["text", "image"],
              output_modalities: ["image"],
            },
          },
        ],
      },
      "openrouter/vendor/pic",
    );
    expect(entry.id).toBe("vendor/pic");

    const tailEntry = providerModelsEntry(
      {
        data: [
          {
            id: "pic",
            architecture: {
              input_modalities: ["text", "image"],
              output_modalities: ["image"],
            },
          },
        ],
      },
      "openai/pic",
    );
    const { facts, meta } = staticExtract("pic", { model: "openai/pic" }, {}, null, tailEntry);
    expect(facts.operations?.edit?.supported).toBe(true);
    expect(meta.sources).toContain("provider.architecture");
  });

  it("reads replicate-style input schemas", () => {
    const entry = {
      id: "m",
      input_schema: {
        properties: { prompt: {}, image: {}, mask: {}, aspect_ratio: {} },
      },
    };
    const { facts } = staticExtract(
      "m",
      { model: "m" },
      { mode: "image_generation" },
      null,
      entry,
    );
    expect(facts.operations?.inpaint?.supported).toBe(true);
    expect(facts.operations?.edit?.supported).toBe(true);
  });

  it("family hints are low-confidence inferred facts", () => {
    const { facts } = staticExtract(
      "cb/dall-e-3",
      { model: "dall-e-3" },
      { mode: "image_generation" },
    );
    expect(facts.operations?.edit?.supported).toBe(false);
    expect(facts.operations?.edit?.source).toBe("inferred");
    expect(facts.sizes?.native).toContain("1792x1024");
    expect(facts.sizes?.source).toBe("inferred");
  });

  it("cost map lookup matches the tail", () => {
    expect(costMapLookup(COST_MAP, "openai/gpt-image-2").output_cost_per_image).toBe(0.04);
  });

  it("direct edit transport overrides every multipart hint", () => {
    const { facts, meta } = staticExtract(
      "cb/gpt-image-2",
      { model: "openai/gpt-image-2", edit_transport: "direct" },
      { mode: "image_generation" },
      COST_MAP,
    );
    expect(facts.operations?.edit).toEqual({
      supported: true,
      source: "declared",
      confidence: 0.85,
    });
    for (const op of [
      "inpaint",
      "multi_image",
      "outpaint",
      "reference_style",
      "remove_background",
      "upscale",
    ]) {
      expect(facts.operations?.[op]?.supported).toBe(false);
    }
    expect(meta.edit_transport).toBe("direct");
  });
});

describe("card basics (capabilities.py)", () => {
  it("default card is conservative", () => {
    const card = defaultCard("m");
    expect(card.schema).toBe(CARD_SCHEMA);
    expect(PUBLIC_SCHEMA).toBe(2);
    expect(OPERATIONS).toHaveLength(10);
    expect(supports(card, "generate")).toBe(true);
    for (const op of ["edit", "inpaint", "multi_image", "transparent_output", "upscale"]) {
      expect(supports(card, op)).toBe(false);
    }
    expect(card.sizes.native).toEqual([DEFAULT_SIZE]);
    expect(card.state).toBe("default");
  });

  it("fingerprint ignores the key and trailing base-url slash but tracks the model", () => {
    const a = fingerprint("m", { model: "x", api_base: "https://a/v1", api_key: "k1" });
    expect(a).toBe(fingerprint("m", { model: "x", api_base: "https://a/v1/", api_key: "k2" }));
    expect(a).not.toBe(fingerprint("m", { model: "x", api_base: "https://b/v1" }));
    expect(a).not.toBe(fingerprint("m", { model: "y", api_base: "https://a/v1" }));
    expect(a).not.toBe(fingerprint("n", { model: "x", api_base: "https://a/v1" }));
    expect(a).not.toBe(
      fingerprint("m", { model: "x", api_base: "https://a/v1", edit_transport: "direct" }),
    );
  });

  it("slugs are stable, opaque, and derived only from the model", () => {
    const slug = slugFor("cb/gpt-image-2");
    expect(slug).toBe(slugFor("cb/gpt-image-2"));
    expect(slug).toMatch(/^ovid-image:img-[0-9a-f]{6}$/);
    expect(slug).not.toContain("gpt");
    expect(slug).not.toContain("cb");
    expect(slug).not.toContain("provider");
    expect(defaultCard("m").slug).toBe(slugFor("m"));
  });

  it("a probed source is not downgraded by an inferred merge", () => {
    const card = defaultCard("m");
    card.operations.edit = cap(true, "probed", 0.9);
    mergeFacts(card, { operations: { edit: cap(false, "inferred", 0.4) } });
    expect(supports(card, "edit")).toBe(true);
  });

  it("cost tiers are relative, with Python's median boundaries", () => {
    const cards = ["a", "b", "c"].map((n) => defaultCard(n));
    [0.01, 0.04, 0.2].forEach((cost, i) => {
      cards[i]!.measured_cost_usd = cost;
    });
    assignCostTiers(cards);
    expect(cards.map((c) => c.cost_tier)).toEqual(["low", "med", "high"]);

    // median = costs[len // 2]; <= 0.6x median is low, >= 1.8x median is high.
    const edge = ["a", "b"].map((n) => defaultCard(n));
    edge[0]!.measured_cost_usd = 0.06;
    edge[1]!.measured_cost_usd = 0.1;
    assignCostTiers(edge);
    expect(edge.map((c) => c.cost_tier)).toEqual(["low", "med"]);

    const high = ["a", "b", "c"].map((n) => defaultCard(n));
    high[0]!.measured_cost_usd = 0.1;
    high[1]!.measured_cost_usd = 0.18;
    high[2]!.measured_cost_usd = 0.324;
    assignCostTiers(high);
    expect(high.map((c) => c.cost_tier)).toEqual(["low", "med", "high"]);

    const single = defaultCard("solo");
    single.measured_cost_usd = 0.2;
    assignCostTiers([single]);
    expect(single.cost_tier).toBe("med");
  });

  it("maxInputs derives from multi_image/edit support", () => {
    const card = defaultCard("m");
    expect(maxInputs(card)).toBe(0);
    card.operations.edit = cap(true, "probed", 0.9);
    expect(maxInputs(card)).toBe(1);
    card.operations.multi_image = cap(true, "probed", 0.9, { max_inputs: 3 });
    expect(maxInputs(card)).toBe(3);
  });

  it("deriveTags and finalize use only card facts", () => {
    const card = defaultCard("m");
    card.latency_ms_p50 = 8000;
    card.quality = "high";
    card.cost_tier = "low";
    card.text_rendering = { level: "good", source: "probed", confidence: 0.8 };
    card.operations.edit = cap(true, "probed", 0.9);
    card.operations.transparent_output = cap(true, "probed", 0.9);
    finalize(card);
    expect(card.tags).toEqual(["fast", "quality", "cheap", "text", "editor", "transparent"]);
    expect(deriveTags(card, "high")).not.toContain("cheap");
  });

  it("ratioOf normalizes with gcd", () => {
    expect(ratioOf("1536x1024")).toBe("3:2");
    expect(ratioOf("1024x1024")).toBe("1:1");
    expect(ratioOf("nope")).toBeNull();
  });

  it("legacyCard declares the operator's sizes and edit flag", () => {
    const card = legacyCard("m", ["1024x1024", "1536x1024"], true);
    expect(card.state).toBe("declared");
    expect(card.operations.edit).toEqual({
      supported: true,
      source: "declared",
      confidence: 0.9,
    });
    expect(card.sizes.source).toBe("declared");
    expect(card.sizes.native).toEqual(["1024x1024", "1536x1024"]);
    expect(card.sizes.aspect_ratios).toEqual(["1:1", "3:2"]);
    expect(card.input.max_images).toBe(1);
  });

  it("clone is deep", () => {
    const card = defaultCard("m");
    const copy = clone(card);
    copy.operations.generate!.supported = false;
    expect(card.operations.generate!.supported).toBe(true);
  });
});

describe("public projection (capabilities.py)", () => {
  function poisonedCard() {
    const { facts, meta } = staticExtract(
      "cb/gpt-image-2",
      PARAMS,
      { mode: "image_generation" },
      COST_MAP,
    );
    const card = mergeFacts(
      defaultCard("cb/gpt-image-2", fingerprint("cb/gpt-image-2", PARAMS)),
      facts,
    );
    card.static = meta;
    card.latency_ms_p50 = 9000;
    finalize(card);
    return card;
  }

  it("never leaks provider internals — the key set is an allow-list", () => {
    const publicValue = publicCard(poisonedCard());
    expect(Object.keys(publicValue).sort()).toEqual(
      [
        "aspect_ratios",
        "cost_tier",
        "input",
        "latency_p50_s",
        "max_n",
        "operations",
        "output_formats",
        "quality",
        "sizes",
        "slug",
        "speed",
        "tags",
        "text_rendering",
        "verified",
      ].sort(),
    );
    expect(Object.keys(publicValue.input as object).sort()).toEqual(["formats", "max_images"]);
    expect(Object.keys(publicValue.operations as object).sort()).toEqual(
      ["edit", "generate", "inpaint", "multi_image", "transparent_output"].sort(),
    );

    const blob = JSON.stringify(publicValue);
    for (const secret of [
      "gpt-image",
      "cb/",
      "secret-provider",
      "openai",
      "cost_usd",
      "0.04",
      "fingerprint",
      "api_base",
      "provider",
    ]) {
      expect(blob).not.toContain(secret);
    }
    expect(publicValue.slug).toBe(slugFor("cb/gpt-image-2"));
    expect(publicValue.cost_tier).toBe("med");
    expect(publicValue.speed).toBe("medium");
    expect(publicValue.latency_p50_s).toBe(9);
    expect(publicValue.verified).toBe(false);
  });

  it("marks probed operations verified and includes max_inputs/max_n", () => {
    const card = defaultCard("m");
    card.state = "probed";
    card.operations.multi_image = cap(true, "probed", 0.9, { max_inputs: 4 });
    card.operations.variations = cap(true, "probed", 0.8, { max_n: 2 });
    card.max_n = 2;
    const publicValue = publicCard(card);
    expect(publicValue.verified).toBe(true);
    expect(publicValue.operations.multi_image).toEqual({ confidence: "verified", max_inputs: 4 });
    expect(publicValue.operations.variations).toEqual({ confidence: "verified", max_n: 2 });
    expect(publicValue.operations.generate).toEqual({ confidence: "estimated" });
  });

  it("speed thresholds are fast <= 8000, medium <= 25000, else slow", () => {
    const card = defaultCard("m");
    card.latency_ms_p50 = 8000;
    expect(publicCard(card).speed).toBe("fast");
    card.latency_ms_p50 = 8001;
    expect(publicCard(card).speed).toBe("medium");
    card.latency_ms_p50 = 25000;
    expect(publicCard(card).speed).toBe("medium");
    card.latency_ms_p50 = 25001;
    expect(publicCard(card).speed).toBe("slow");
    card.latency_ms_p50 = null;
    expect(publicCard(card).speed).toBe("unknown");
    expect(publicCard(card).latency_p50_s).toBeNull();
  });

  it("catalog hash is order-independent and content-sensitive", () => {
    const a = publicCard(legacyCard("a", ["1024x1024"], true));
    const b = publicCard(legacyCard("b", ["1024x1024"], false));
    expect(catalogHash([a, b])).toBe(catalogHash([b, a]));
    expect(catalogHash([a, b])).not.toBe(catalogHash([a]));
    expect(catalogHash([a])).toMatch(/^[0-9a-f]{32}$/);
  });
});
