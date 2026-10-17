import {
  DEFAULT_SIZE,
  SIZE_RE,
  cap,
  ratioOf,
  type CardFacts,
  type CapabilityRecord,
} from "./capabilities.js";
import { SIZES } from "./types.js";

/**
 * Port of server/images/extraction.py — static capability extraction: no paid
 * call, no user request path.
 *
 * Sources, weakest to strongest (all produce 'inferred'/'declared' facts):
 *  1. name hints for well-known image model families (low confidence)
 *  2. LiteLLM /model/info `model_info` + its built-in cost-map metadata
 *  3. the raw LiteLLM cost map (optional, fetched in the background)
 *  4. the provider's own models API when the base URL exposes it
 *
 * Probes later overwrite any of this with measured truth.
 */

interface FamilyHint {
  sizes?: string[];
  edit?: boolean;
  inpaint?: boolean;
  outpaint?: boolean;
  reference_style?: boolean;
  multi_image?: number;
  transparent?: boolean;
  remove_background?: boolean;
  upscale?: boolean;
  variations?: boolean;
  text?: "none" | "ok" | "good";
  quality?: "low" | "med" | "high";
  max_n?: number;
  formats?: string[];
}

/** (regex on lowercase model name) -> hints. Hints are guesses; confidence is low. */
const FAMILIES: [RegExp, FamilyHint][] = [
  [
    /gpt-image/,
    {
      sizes: ["1024x1024", "1536x1024", "1024x1536"],
      edit: true,
      inpaint: true,
      multi_image: 16,
      transparent: true,
      text: "good",
      quality: "high",
      formats: ["png", "jpeg", "webp"],
    },
  ],
  [
    /dall-e-3/,
    {
      sizes: ["1024x1024", "1792x1024", "1024x1792"],
      edit: false,
      text: "ok",
      quality: "high",
      max_n: 1,
    },
  ],
  [
    /dall-e-2/,
    {
      sizes: ["256x256", "512x512", "1024x1024"],
      edit: true,
      inpaint: true,
      variations: true,
      text: "none",
      quality: "low",
      max_n: 10,
    },
  ],
  [
    /gemini.*image|nano-banana/,
    {
      sizes: ["1024x1024", "1536x1024", "1024x1536"],
      edit: true,
      multi_image: 3,
      text: "good",
      quality: "high",
    },
  ],
  [
    /imagen/,
    {
      sizes: ["1024x1024", "1536x1024", "1024x1536"],
      edit: false,
      text: "ok",
      quality: "high",
      max_n: 4,
    },
  ],
  [/flux.*(fill|inpaint)/, { edit: true, inpaint: true, outpaint: true, quality: "high" }],
  [/flux.*(kontext)/, { edit: true, reference_style: true, text: "good", quality: "high" }],
  [/flux.*schnell|turbo|lightning|lcm|sdxl-turbo/, { quality: "low", text: "none" }],
  [/flux/, { quality: "high", text: "ok" }],
  [
    /stable-diffusion|sdxl|sd3/,
    { edit: true, inpaint: true, text: "none", quality: "med" },
  ],
  [/upscal|esrgan|clarity/, { upscale: true, edit: true }],
  [
    /rembg|remove-?bg|background-?remov|birefnet/,
    { remove_background: true, edit: true, transparent: true },
  ],
];

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Python truthiness: `[]`, `{}`, `""`, `0`, `False` and None are falsy. */
function pyTruthy(value: unknown): boolean {
  if (value === null || value === undefined || value === false || value === 0 || value === "") {
    return false;
  }
  if (Array.isArray(value)) return value.length > 0;
  if (isPlainObject(value)) return Object.keys(value).length > 0;
  return true;
}

/** `_hints`: first family to define a key wins (dict.setdefault). */
function hintsFor(name: string): FamilyHint {
  const merged: FamilyHint = {};
  const lowered = name.toLowerCase();
  for (const [pattern, hint] of FAMILIES) {
    if (!pattern.test(lowered)) continue;
    for (const [key, value] of Object.entries(hint)) {
      if (!(key in merged)) (merged as Record<string, unknown>)[key] = value;
    }
  }
  return merged;
}

function sizesFrom(value: unknown): string[] {
  const out: string[] = [];
  if (!Array.isArray(value)) return out;
  for (let item of value) {
    if (typeof item !== "string") continue;
    item = item.replace(/-x-/g, "x").replace(/X/g, "x").replace(/\*/g, "x");
    if (SIZE_RE.test(item) && !out.includes(item)) out.push(item);
  }
  return out;
}

/** Find the raw LiteLLM cost-map entry for 'provider/model' or 'model'. */
export function costMapLookup(
  costMap: unknown,
  litellmModel: string | null | undefined,
): Record<string, unknown> {
  if (!isPlainObject(costMap) || !litellmModel) return {};
  const tail = litellmModel.split("/", 1)[0] === litellmModel
    ? litellmModel
    : litellmModel.slice(litellmModel.indexOf("/") + 1);
  for (const key of [litellmModel, tail, litellmModel]) {
    const entry = costMap[key];
    if (isPlainObject(entry)) return entry;
  }
  return {};
}

/** Pick this model's row from an OpenRouter/[OI]-style GET /models body. */
export function providerModelsEntry(
  listing: unknown,
  litellmModel: string | null | undefined,
): Record<string, unknown> {
  const rows = isPlainObject(listing) ? listing.data : listing;
  if (!Array.isArray(rows) || !litellmModel) return {};
  const tail = litellmModel.split("/", 1)[0] === litellmModel
    ? litellmModel
    : litellmModel.slice(litellmModel.indexOf("/") + 1);
  for (const row of rows) {
    if (isPlainObject(row) && (row.id === litellmModel || row.id === tail)) return row;
  }
  return {};
}

export interface StaticMeta {
  sources: string[];
  edit_transport?: string;
  native_aspect_ratio_param?: boolean;
  cost_source?: string;
  mode?: unknown;
  [extra: string]: unknown;
}

function applyEditTransport(operations: Record<string, CapabilityRecord>, transport: string): void {
  /**
   * Edits go through the provider's documented JSON contract (single image, no
   * mask/background) or are unavailable. This is the provider contract, so it
   * overrides every name hint and LiteLLM claim (which assumed multipart).
   */
  if (transport === "direct") {
    operations.edit = cap(true, "declared", 0.85);
    for (const operation of [
      "inpaint",
      "multi_image",
      "outpaint",
      "reference_style",
      "remove_background",
      "upscale",
    ]) {
      operations[operation] = cap(false, "declared", 0.85);
    }
  } else {
    for (const operation of [
      "edit",
      "inpaint",
      "multi_image",
      "outpaint",
      "reference_style",
      "remove_background",
      "upscale",
    ]) {
      operations[operation] = cap(false, "declared", 0.85);
    }
  }
}

/** Property names from a replicate/fal/HF-style input schema, if present. */
function schemaProps(entry: unknown): Set<string> {
  if (!isPlainObject(entry)) return new Set();
  const paths: string[][] = [
    ["input_schema", "properties"],
    ["openapi_schema", "components", "schemas", "Input", "properties"],
    ["schema", "input", "properties"],
    ["parameters", "properties"],
  ];
  for (const path of paths) {
    let node: unknown = entry;
    for (const part of path) {
      node = isPlainObject(node) ? node[part] : undefined;
    }
    if (isPlainObject(node)) return new Set(Object.keys(node));
  }
  return new Set();
}

/** -> facts to merge into a card; meta is admin-only. */
export function staticExtract(
  name: string,
  litellmParams: Record<string, unknown> | null | undefined = {},
  modelInfo: Record<string, unknown> | null | undefined = {},
  costMap: unknown = null,
  providerEntry: unknown = null,
): { facts: CardFacts; meta: StaticMeta } {
  const params = litellmParams ?? {};
  const info = modelInfo ?? {};
  const litellmModel =
    typeof params.model === "string" && params.model !== "" ? params.model : name;
  const raw = costMapLookup(costMap, litellmModel);
  const merged: Record<string, unknown> = { ...raw };
  for (const [key, value] of Object.entries(info)) {
    if (value !== undefined && value !== null) merged[key] = value;
  }
  const hint = hintsFor(`${name} ${litellmModel}`);
  const operations: Record<string, CapabilityRecord> = {};
  const meta: StaticMeta = { sources: [] };

  const mode = merged.mode;
  if (mode === "image_generation" || merged.output_modality === "image") {
    operations.generate = cap(true, "declared", 0.9);
    meta.sources.push("litellm.mode");
  }

  const endpoints = merged.supported_endpoints;
  if (Array.isArray(endpoints) && endpoints.length > 0) {
    meta.sources.push("litellm.supported_endpoints");
    const edits = endpoints.some((entry) => String(entry).includes("/images/edits"));
    operations.edit = cap(edits, "declared", 0.85);
  }
  const inputModalities = merged.supported_modalities;
  if (Array.isArray(inputModalities) && !("edit" in operations)) {
    meta.sources.push("litellm.supported_modalities");
    operations.edit = cap(inputModalities.includes("image"), "inferred", 0.6);
  }

  // extraction.py: `merged.get('supported_sizes') or merged.get('sizes')` —
  // Python truthiness, so an empty list falls through to `sizes`.
  let sizes = sizesFrom(
    pyTruthy(merged.supported_sizes) ? merged.supported_sizes : merged.sizes,
  );
  if (sizes.length > 0) meta.sources.push("litellm.sizes");
  let sizesSource: "declared" | "inferred" = sizes.length > 0 ? "declared" : "inferred";
  const sizesConfidence = sizes.length > 0 ? 0.85 : 0.4;

  // Provider models API (OpenRouter style).
  const architecture = isPlainObject(providerEntry) ? providerEntry.architecture : undefined;
  if (isPlainObject(architecture)) {
    meta.sources.push("provider.architecture");
    const inputs = architecture.input_modalities;
    const outputs = architecture.output_modalities;
    if (Array.isArray(outputs) && outputs.includes("image")) {
      if (!("generate" in operations)) operations.generate = cap(true, "declared", 0.8);
    }
    if (Array.isArray(inputs) && inputs.length > 0) {
      operations.edit = cap(inputs.includes("image"), "declared", 0.8);
    }
  }
  const schema = schemaProps(providerEntry);
  if (schema.size > 0) {
    meta.sources.push("provider.schema");
    const intersects = (names: string[]): boolean => names.some((n) => schema.has(n));
    if (intersects(["mask", "mask_image", "mask_url"])) {
      operations.inpaint = cap(true, "declared", 0.8);
    }
    if (intersects(["image", "image_url", "input_image", "init_image", "image_input"])) {
      if (!("edit" in operations)) operations.edit = cap(true, "declared", 0.7);
    }
    if (intersects(["image_urls", "input_images", "images", "reference_images"])) {
      operations.multi_image = cap(true, "declared", 0.7, { max_inputs: 4 });
    }
    if (schema.has("aspect_ratio")) meta.native_aspect_ratio_param = true;
    if (intersects(["num_outputs", "num_images", "n"])) {
      operations.variations = cap(true, "declared", 0.6);
    }
  }

  // Name-family hints: only fill what nothing better said.
  const hinted = (operation: string): void => {
    if (hint[operation as keyof FamilyHint] && !(operation in operations)) {
      operations[operation] = cap(true, "inferred", 0.4);
    }
  };
  if ("edit" in hint && !("edit" in operations)) {
    operations.edit = cap(Boolean(hint.edit), "inferred", 0.45);
  }
  for (const operation of [
    "inpaint",
    "outpaint",
    "reference_style",
    "upscale",
    "remove_background",
    "variations",
  ]) {
    hinted(operation);
  }
  if (hint.multi_image && !("multi_image" in operations)) {
    operations.multi_image = cap(true, "inferred", 0.4, {
      max_inputs: Number(hint.multi_image),
    });
  }
  if (hint.transparent && !("transparent_output" in operations)) {
    operations.transparent_output = cap(true, "inferred", 0.4);
  }
  if (sizes.length === 0 && hint.sizes) {
    sizes = [...hint.sizes];
    sizesSource = "inferred";
  }
  if (sizes.length > 0) {
    meta.sources.push(sizesSource === "inferred" ? "name_hint" : "declared_sizes");
  }

  const transport = params.edit_transport;
  if (transport === "direct" || transport === "none") {
    applyEditTransport(operations, transport);
    meta.edit_transport = transport;
  }

  const facts: CardFacts = { operations };
  if (sizes.length > 0) {
    facts.sizes = {
      native: sizes,
      source: sizesSource,
      confidence: sizesConfidence,
      aspect_ratios: [...new Set(sizes.map(ratioOf).filter((ratio): ratio is string => ratio !== null))].sort(),
    };
  }
  if (hint.text) {
    facts.text_rendering = { level: hint.text, source: "inferred", confidence: 0.35 };
  }
  if (hint.quality) facts.quality = hint.quality;
  if (hint.max_n) facts.max_n = Number(hint.max_n);
  if (hint.formats) facts.input = { formats: hint.formats };
  const cost = merged.output_cost_per_image;
  if (typeof cost === "number" && Number.isFinite(cost) && cost > 0) {
    facts.measured_cost_usd = cost;
    meta.cost_source = "litellm.output_cost_per_image";
  }
  if (Object.keys(hint).length > 0) meta.sources.push("name_hint");
  meta.mode = mode;
  return { facts, meta };
}

/** Candidate sizes to probe, declared/inferred first, bounded by `limit`. */
export function defaultProbeSizes(facts: CardFacts, limit: number): string[] {
  const seen = [...(facts.sizes?.native ?? [])];
  for (const size of SIZES) {
    if (!seen.includes(size)) seen.push(size);
  }
  const index = seen.indexOf(DEFAULT_SIZE);
  if (index !== -1) seen.splice(index, 1);
  return [DEFAULT_SIZE, ...seen.slice(0, Math.max(0, limit - 1))];
}
