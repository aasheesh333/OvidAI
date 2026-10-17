import { describe, expect, it } from "vitest";
import { cap, defaultCard, finalize, type Card } from "./capabilities.js";
import {
  PREFERENCES,
  alternatives,
  missing,
  parseModel,
  pickBackends,
  score,
  taskFromRequest,
  type Task,
} from "./routing.js";

function card(
  model: string,
  opts: {
    edit?: boolean;
    inpaint?: boolean;
    multi?: number;
    transparent?: boolean;
    sizes?: string[];
    ratios?: string[];
    latency?: number | null;
    cost?: "low" | "med" | "high";
    quality?: "low" | "med" | "high";
    text?: "none" | "ok" | "good";
    state?: "default" | "inferred" | "probed";
    editTransport?: "direct" | "none" | null;
    priced?: boolean;
  } = {},
): Card {
  const c = defaultCard(model);
  c.state = opts.state ?? "probed";
  c.operations.edit = cap(opts.edit ?? false, "probed", 0.9);
  c.operations.inpaint = cap(opts.inpaint ?? false, "probed", 0.9);
  c.operations.multi_image = cap(Boolean(opts.multi), "probed", 0.9, {
    max_inputs: opts.multi ?? 0,
  });
  c.operations.transparent_output = cap(opts.transparent ?? false, "probed", 0.9);
  c.sizes = {
    native: [...(opts.sizes ?? ["1024x1024"])],
    aspect_ratios: [...(opts.ratios ?? ["1:1"])],
    source: "probed",
    confidence: 0.9,
  };
  c.latency_ms_p50 = opts.latency ?? null;
  c.cost_tier = opts.cost ?? "med";
  c.quality = opts.quality ?? "med";
  c.text_rendering = { level: opts.text ?? "none", source: "inferred", confidence: 0.5 };
  c.edit_transport = opts.editTransport ?? null;
  c.priced = opts.priced ?? true;
  return finalize(c);
}

function task(partial: Partial<Task> = {}): Task {
  return {
    operation: "generate",
    size: null,
    aspect_ratio: null,
    n_inputs: 0,
    mask: false,
    transparent: false,
    text_rendering: false,
    preference: "balanced",
    ...partial,
  };
}

const CARDS = [
  card("cheap-fast", { latency: 4000, cost: "low", quality: "low" }),
  card("editor", {
    edit: true,
    inpaint: true,
    multi: 3,
    latency: 20000,
    cost: "med",
    quality: "med",
    sizes: ["1024x1024", "1536x1024"],
    ratios: ["1:1", "3:2"],
  }),
  card("pro", {
    edit: true,
    inpaint: true,
    multi: 8,
    transparent: true,
    latency: 40000,
    cost: "high",
    quality: "high",
    text: "good",
    sizes: ["1024x1024", "1536x1024", "1024x1536"],
    ratios: ["1:1", "3:2", "2:3"],
  }),
];

function models(taskValue: Task, unavailable?: (model: string) => boolean): string[] {
  return pickBackends(taskValue, CARDS, unavailable).map((c) => c.model);
}

describe("routing.py — preferences and hard filters", () => {
  it("orders by preference", () => {
    expect(models(task({ preference: "cost" }))[0]).toBe("cheap-fast");
    expect(models(task({ preference: "speed" }))[0]).toBe("cheap-fast");
    expect(models(task({ preference: "quality" }))[0]).toBe("pro");
  });

  it("hard-filters by operation, inputs, transparency, size and ratio", () => {
    expect(models(task({ operation: "edit", n_inputs: 1 })).sort()).toEqual(["editor", "pro"]);
    expect(
      models(task({ operation: "inpaint", mask: true, n_inputs: 1, preference: "cost" })),
    ).toEqual(["editor", "pro"]);
    expect(models(task({ operation: "edit", n_inputs: 5 }))).toEqual(["pro"]);
    expect(models(task({ operation: "generate", transparent: true }))).toEqual(["pro"]);
    expect(models(task({ operation: "generate", size: "1536x1024" })).sort()).toEqual([
      "editor",
      "pro",
    ]);
    expect(models(task({ operation: "generate", aspect_ratio: "2:3" }))).toEqual(["pro"]);
    expect(models(task({ operation: "generate", size: "2048x2048" }))).toEqual([]);
  });

  it("checks every operation Python's needs() can require", () => {
    const base = card("x", { edit: true });
    const cases: [Task["operation"], string][] = [
      ["inpaint", "inpaint"],
      ["outpaint", "outpaint"],
      ["reference_style", "reference_style"],
      ["multi_image", "multi_image"],
      ["remove_background", "remove_background"],
      ["upscale", "upscale"],
      ["variations", "variations"],
    ];
    for (const [operation, required] of cases) {
      // The base card supports edit only, so every refinement is missing.
      expect(missing(base, task({ operation, n_inputs: 1 }))).toContain(required);
    }
  });

  it("a text-rendering need overrides the cost preference", () => {
    expect(models(task({ text_rendering: true, preference: "cost" }))[0]).toBe("pro");
  });

  it("cooldown-blocked models are skipped, never ranked", () => {
    expect(
      models(task({ operation: "edit", n_inputs: 1, preference: "quality" }), (m) => m === "pro"),
    ).toEqual(["editor"]);
    expect(models(task(), (m) => m !== "editor")).toEqual(["editor"]);
  });

  it("a verified card beats a guessed one when otherwise equal", () => {
    const guessed = card("guess", { state: "inferred" });
    const proven = card("proof", { state: "probed" });
    expect(pickBackends(task(), [guessed, proven]).map((c) => c.model)).toEqual([
      "proof",
      "guess",
    ]);
  });

  it("stable ties keep discovery order", () => {
    const twins = [card("b"), card("a")];
    expect(pickBackends(task(), twins).map((c) => c.model)).toEqual(["b", "a"]);
  });

  it("every preference is known and yields a candidate", () => {
    for (const preference of PREFERENCES) {
      expect(models(task({ preference })).length).toBeGreaterThan(0);
    }
  });

  it("missing and alternatives use slugs", () => {
    expect(missing(CARDS[0]!, task({ operation: "edit", n_inputs: 1 }))).toEqual(["edit"]);
    expect(
      new Set(alternatives(task({ operation: "edit", n_inputs: 1 }), CARDS)),
    ).toEqual(new Set([CARDS[1]!.slug, CARDS[2]!.slug]));
  });
});

describe("routing.py — exact score weights", () => {
  it("uses quality/speed/(1-cost) with the preference tables", () => {
    const c = card("x", { latency: 40000, cost: "high", quality: "high", text: "good" });
    const speed = 1 - 40000 / 60000;
    // balanced = 1*q + 1*speed + 1*(1-cost) + 0.15 probed
    expect(score(c, task())).toBeCloseTo(1 + speed + 0 + 0.15, 10);
    // quality = 3*q + 0.5*speed + 0.3*(1-cost)
    expect(score(c, task({ preference: "quality" }))).toBeCloseTo(3 + 0.5 * speed + 0.15, 10);
    // speed = 0.4*q + 3*speed + 0.4*(1-cost)
    expect(score(c, task({ preference: "speed" }))).toBeCloseTo(
      0.4 + 3 * speed + 0.15,
      10,
    );
    // cost = 0.3*q + 0.4*speed + 3*(1-cost)
    expect(score(c, task({ preference: "cost" }))).toBeCloseTo(0.3 + 0.4 * speed + 0.15, 10);
    // a text need adds 3 * text level (good = 1.0)
    expect(score(c, task({ text_rendering: true }))).toBeCloseTo(1 + speed + 3 + 0.15, 10);
  });

  it("treats a missing latency as speed 0.5 and unknown tiers as med", () => {
    const c = card("x");
    c.latency_ms_p50 = null;
    c.cost_tier = "bogus" as never;
    c.quality = "bogus" as never;
    expect(score(c, task())).toBeCloseTo(0.5 + 0.5 + 0.5 + 0.15, 10);
  });
});

describe("routing.py — unpriced never serves", () => {
  it("missing() reports unpriced and pick_backends drops it", () => {
    const priced = card("priced");
    const unpriced = card("unpriced", { priced: false });
    expect(missing(unpriced, task())).toContain("unpriced");
    expect(pickBackends(task(), [unpriced, priced]).map((c) => c.model)).toEqual(["priced"]);
    expect(alternatives(task(), [unpriced, priced])).toEqual([priced.slug]);
  });
});

describe("routing.py — direct-transport transparency refusal", () => {
  it("refuses a transparent edit on a direct card, but not a transparent generate", () => {
    const direct = card("direct", {
      edit: true,
      transparent: true,
      editTransport: "direct",
    });
    const edit = task({ operation: "inpaint", n_inputs: 1, transparent: true });
    expect(missing(direct, edit)).toContain("transparent_output");
    expect(pickBackends(edit, [direct])).toEqual([]);
    expect(missing(direct, task({ operation: "generate", transparent: true }))).toEqual([]);
  });
});

describe("routing.py — parse_model", () => {
  it("maps the alias to auto and validates the slug shape", () => {
    expect(parseModel("ovid-image")).toBeNull();
    expect(parseModel("ovid-image:img-abc123")).toBe("ovid-image:img-abc123");
    expect(parseModel("ovid-image:img-a_b-c")).toBe("ovid-image:img-a_b-c");
    for (const bad of ["gpt-image-2", "ovid-image:", "ovid-image:a b", null, 3, ""]) {
      expect(() => parseModel(bad)).toThrow();
    }
  });
});

describe("routing.py — task_from_request", () => {
  it("builds the task shape", () => {
    const t = taskFromRequest("generate", { prompt: "x", size: "1024x1024" });
    expect([t.operation, t.size, t.n_inputs]).toEqual(["generate", "1024x1024", 0]);
    const edit = taskFromRequest("edit", { image: "i", mask: "m" });
    expect([edit.operation, edit.mask, edit.n_inputs]).toEqual(["inpaint", true, 1]);
    const multi = taskFromRequest("edit", { image: "i", images: ["a", "b"] });
    expect([multi.operation, multi.n_inputs]).toEqual(["multi_image", 3]);
    const removed = taskFromRequest("edit", {
      image: "i",
      requirements: { operation: "remove_background" },
      preference: "cost",
    });
    expect([removed.operation, removed.preference]).toEqual(["remove_background", "cost"]);
  });

  it("counts inputs with Python truthiness (mask '' and images null are absent)", () => {
    const t = taskFromRequest("edit", { image: "", mask: "", images: null });
    expect([t.operation, t.mask, t.n_inputs]).toEqual(["edit", false, 0]);
  });

  it("uses Python truthiness for mask and requirement booleans", () => {
    // bool({}) and bool([]) are False in Python; JS Boolean() would say true.
    const empty = taskFromRequest("generate", {
      mask: {},
      requirements: { transparent_background: {}, text_rendering: [] },
    });
    expect([empty.mask, empty.transparent, empty.text_rendering]).toEqual([
      false,
      false,
      false,
    ]);
    const set = taskFromRequest("generate", {
      mask: { any: true },
      requirements: { transparent_background: [1], text_rendering: { on: true } },
    });
    expect([set.mask, set.transparent, set.text_rendering]).toEqual([true, true, true]);
  });

  it("allows every TASK_OPERATION on the matching endpoint only", () => {
    for (const op of ["generate", "variations"]) {
      expect(taskFromRequest("generate", { requirements: { operation: op } }).operation).toBe(op);
    }
    for (const op of [
      "edit",
      "inpaint",
      "outpaint",
      "reference_style",
      "multi_image",
      "remove_background",
      "upscale",
      "variations",
    ]) {
      expect(taskFromRequest("edit", { requirements: { operation: op } }).operation).toBe(op);
    }
    expect(() =>
      taskFromRequest("generate", { requirements: { operation: "edit" } }),
    ).toThrow();
    expect(() =>
      taskFromRequest("generate", { requirements: { operation: "upscale" } }),
    ).toThrow();
    expect(() =>
      taskFromRequest("edit", { requirements: { operation: "generate" } }),
    ).toThrow();
  });

  it("rejects unknown requirements, preferences, ratios, and >8 extra images", () => {
    const bad: Record<string, unknown>[] = [
      { requirements: { x: 1 } },
      { requirements: { operation: "edit" } },
      { preference: "fancy" },
      { requirements: { aspect_ratio: "wide" } },
      { requirements: { aspect_ratio: "0:0" } },
      { requirements: { aspect_ratio: "00:01" } },
      { images: Array.from({ length: 9 }, (_, i) => `i${i}`) },
      { images: "not-a-list" },
      { size: "1024" },
      { size: "0x0" },
    ];
    for (const body of bad) {
      expect(() => taskFromRequest("generate", body), JSON.stringify(body)).toThrow();
    }
    expect(() => taskFromRequest("edit", { requirements: "nope" })).toThrow();
  });

  it("accepts a syntactically valid non-SIZES size for the 422 routing gate", () => {
    expect(taskFromRequest("generate", { size: "999x999" }).size).toBe("999x999");
    expect(taskFromRequest("generate", { requirements: { aspect_ratio: "16:9" } }).aspect_ratio).toBe(
      "16:9",
    );
  });
});
