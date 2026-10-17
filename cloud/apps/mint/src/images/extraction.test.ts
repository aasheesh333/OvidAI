import { describe, expect, it } from "vitest";
import { staticExtract } from "./extraction.js";

/**
 * extraction.py: `merged.get('supported_sizes') or merged.get('sizes')` uses
 * Python truthiness, so an empty supported_sizes list falls through instead of
 * discarding a non-empty `sizes`.
 */
describe("extraction.py — declared size fallback", () => {
  it("falls through an empty supported_sizes to sizes", () => {
    const { facts } = staticExtract("m", {}, {
      supported_sizes: [],
      sizes: ["512x512"],
    });
    expect(facts.sizes?.native).toEqual(["512x512"]);
  });

  it("prefers a non-empty supported_sizes", () => {
    const { facts } = staticExtract("m", {}, {
      supported_sizes: ["1024x1024"],
      sizes: ["512x512"],
    });
    expect(facts.sizes?.native).toEqual(["1024x1024"]);
  });
});
