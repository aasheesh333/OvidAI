import { createHash } from "node:crypto";

/**
 * Port of server/images/capabilities.py — versioned image-model capability
 * cards (pure data, no I/O).
 *
 * A card describes what ONE LiteLLM image model can do. It is filled
 * automatically (static extraction + background probes); nobody edits it by
 * hand. The *private* card carries internal model names, measured cost and
 * probe results for the owner. The *public* card is the only projection that
 * crosses the API boundary: stable opaque slug, ops, sizes, tiers — never a
 * provider name, base URL or price.
 */

export const CARD_SCHEMA = 1;
export const PUBLIC_SCHEMA = 2;
export const ALIAS = "ovid-image";

/** Every operation a card can advertise (capabilities.py OPERATIONS). */
export const OPERATIONS = [
  "generate",
  "edit",
  "inpaint",
  "outpaint",
  "reference_style",
  "multi_image",
  "remove_background",
  "transparent_output",
  "upscale",
  "variations",
] as const;
export type Operation = (typeof OPERATIONS)[number];

export const SOURCES = ["declared", "inferred", "probed"] as const;
export type Source = (typeof SOURCES)[number];

export const DEFAULT_SIZE = "1024x1024";
export const COST_TIERS = ["low", "med", "high"] as const;
export const TEXT_LEVELS = ["none", "ok", "good"] as const;

/** capabilities.py SIZE_RE. */
export const SIZE_RE = /^([1-9][0-9]{2,3})x([1-9][0-9]{2,3})$/;

export interface CapabilityRecord {
  supported: boolean | null;
  source: Source;
  confidence: number;
  [extra: string]: unknown;
}

export interface CardSizes {
  native: string[];
  aspect_ratios: string[];
  source: Source;
  confidence: number;
}

export interface CardInput {
  max_images: number;
  max_bytes: number;
  max_pixels: number;
  formats: string[];
}

export interface TextRendering {
  level: string;
  source: Source;
  confidence: number;
}

export interface ProbeResult {
  probe: string;
  ok: boolean;
  error_class: string | null;
  latency_ms: number | null;
  cost_usd: number;
  at: number;
}

export interface Card {
  schema: number;
  model: string;
  slug: string;
  fingerprint: string;
  state: "default" | "inferred" | "declared" | "probed" | string;
  operations: Record<string, CapabilityRecord>;
  sizes: CardSizes;
  max_n: number;
  input: CardInput;
  output_formats: string[];
  text_rendering: TextRendering;
  latency_ms_p50: number | null;
  cost_tier: string;
  measured_cost_usd: number | null;
  quality: string;
  tags: string[];
  probed_at: number | null;
  static: Record<string, unknown>;
  probes: ProbeResult[];
  /** Private transport marker (never projected publicly). */
  edit_transport?: "direct" | "none" | null;
  /** Live price state, evaluated on every read (never persisted as truth). */
  priced?: boolean;
  cost_source?: string | null;
  warnings?: string[];
  probe_warnings?: string[];
  probe_stop?: string | null;
  cost_header_seen?: boolean;
}

/** The only fields merge_facts may overlay. */
export interface CardFacts {
  operations?: Record<string, CapabilityRecord>;
  sizes?: Partial<CardSizes> & { native?: string[] };
  text_rendering?: Partial<TextRendering> & { level?: string };
  max_n?: number;
  output_formats?: string[];
  latency_ms_p50?: number | null;
  measured_cost_usd?: number | null;
  quality?: string;
  input?: Partial<CardInput>;
}

export interface PublicCard {
  slug: string;
  tags: string[];
  operations: Record<
    string,
    { confidence: "verified" | "estimated"; max_inputs?: number; max_n?: number }
  >;
  sizes: string[];
  aspect_ratios: string[];
  max_n: number;
  input: { max_images: number; formats: string[] };
  output_formats: string[];
  text_rendering: string;
  quality: string;
  speed: "fast" | "medium" | "slow" | "unknown";
  latency_p50_s: number | null;
  cost_tier: string;
  verified: boolean;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Python `json.dumps(..., sort_keys=True)` for the plain JSON shapes these
 * modules hash. `compact` selects `separators=(',', ':')` (catalog_hash);
 * otherwise Python's default `(', ', ': ')` (fingerprint).
 */
export function stableJson(value: unknown, compact = false): string {
  const comma = compact ? "," : ", ";
  const colon = compact ? ":" : ": ";
  function encode(node: unknown): string {
    if (node === null || node === undefined) return "null";
    if (typeof node === "string") {
      // Python ensure_ascii=True: escape every non-ASCII code unit.
      return JSON.stringify(node).replace(
        /[\u007f-￿]/g,
        (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`,
      );
    }
    if (typeof node === "number") {
      if (!Number.isFinite(node)) return "null";
      return String(node);
    }
    if (typeof node === "boolean") return node ? "true" : "false";
    if (Array.isArray(node)) return `[${node.map(encode).join(comma)}]`;
    if (isPlainObject(node)) {
      const keys = Object.keys(node)
        .filter((key) => node[key] !== undefined)
        .sort();
      return `{${keys.map((key) => `${encode(key)}${colon}${encode(node[key])}`).join(comma)}}`;
    }
    return "null";
  }
  return encode(value);
}

/** capabilities.py fingerprint(): model + the params that decide what it is. */
export function fingerprint(
  model: string,
  params: Record<string, unknown> | null | undefined = {},
): string {
  const values = params ?? {};
  const material: Record<string, unknown> = {
    model,
    litellm_model: values.model || "",
    api_base: typeof values.api_base === "string" ? values.api_base.replace(/\/+$/, "") : "",
    provider: values.custom_llm_provider || "",
  };
  if (values.edit_transport) material.edit_transport = values.edit_transport;
  return createHash("sha256").update(stableJson(material)).digest("hex");
}

/** Plan-facing alias for capabilities.fingerprint(). */
export const cardFingerprint = fingerprint;

/** Stable, opaque public slug; survives restarts and reveals nothing. */
export function slugFor(model: string): string {
  return `${ALIAS}:img-${createHash("sha256")
    .update(`ovid-slug|${model}`)
    .digest("hex")
    .slice(0, 6)}`;
}

/** One capability record. supported: true / false / null (unknown). */
export function cap(
  supported: boolean | null = null,
  source: Source = "inferred",
  confidence = 0.5,
  extra: Record<string, unknown> = {},
): CapabilityRecord {
  return {
    supported,
    source,
    confidence: Math.round(confidence * 100) / 100,
    ...extra,
  };
}

function gcd(a: number, b: number): number {
  return b === 0 ? a : gcd(b, a % b);
}

/** capabilities.py ratio_of(). */
export function ratioOf(size: string): string | null {
  const match = SIZE_RE.exec(size);
  if (match === null) return null;
  const width = Number.parseInt(match[1]!, 10);
  const height = Number.parseInt(match[2]!, 10);
  const divisor = gcd(width, height);
  return `${width / divisor}:${height / divisor}`;
}

/** Conservative generate-only 1024x1024 card used until extraction/probing. */
export function defaultCard(model: string, fp?: string): Card {
  const operations: Record<string, CapabilityRecord> = {};
  for (const operation of OPERATIONS) operations[operation] = cap(false, "inferred", 0.3);
  operations.generate = cap(true, "inferred", 0.6);
  return {
    schema: CARD_SCHEMA,
    model,
    slug: slugFor(model),
    fingerprint: fp ?? fingerprint(model),
    state: "default",
    operations,
    sizes: {
      native: [DEFAULT_SIZE],
      aspect_ratios: ["1:1"],
      source: "inferred",
      confidence: 0.4,
    },
    max_n: 1,
    input: {
      max_images: 0,
      max_bytes: 16 * 1024 * 1024,
      max_pixels: 4096 * 4096,
      formats: ["png", "jpeg", "webp"],
    },
    output_formats: ["png"],
    text_rendering: { level: "none", source: "inferred", confidence: 0.2 },
    latency_ms_p50: null,
    cost_tier: "med",
    measured_cost_usd: null,
    quality: "med",
    tags: [],
    probed_at: null,
    static: {},
    probes: [],
  };
}

export function supports(card: Card, operation: string): boolean {
  const record = card.operations[operation];
  return Boolean(record && record.supported === true);
}

/** capabilities.py max_inputs(): derived from multi_image/edit support. */
export function maxInputs(card: Card): number {
  const record = card.operations.multi_image;
  if (record?.supported === true) return Number(record.max_inputs) || 2;
  return supports(card, "edit") ? 1 : 0;
}

export function deriveTags(card: Card, costTier?: string): string[] {
  const tags: string[] = [];
  const latency = card.latency_ms_p50;
  if (latency !== null && latency !== undefined && latency <= 8000) tags.push("fast");
  if (card.quality === "high") tags.push("quality");
  if ((costTier || card.cost_tier) === "low") tags.push("cheap");
  if (card.text_rendering?.level === "good") tags.push("text");
  if (supports(card, "edit")) tags.push("editor");
  if (supports(card, "transparent_output")) tags.push("transparent");
  return tags;
}

/** Relative tiers from measured/static cost. Exact money never leaves. */
export function assignCostTiers(cards: Card[]): void {
  const costs = cards
    .map((card) => card.measured_cost_usd)
    .filter((cost): cost is number => typeof cost === "number" && cost !== 0)
    .sort((left, right) => left - right);
  if (costs.length === 0) return;
  const median = costs[Math.floor(costs.length / 2)]!;
  for (const card of cards) {
    const cost = card.measured_cost_usd;
    if (!cost) continue;
    card.cost_tier = cost <= median * 0.6 ? "low" : cost >= median * 1.8 ? "high" : "med";
  }
  if (costs.length === 1) {
    for (const card of cards) {
      if (card.measured_cost_usd) card.cost_tier = "med";
    }
  }
}

export function finalize(card: Card): Card {
  card.tags = deriveTags(card);
  return card;
}

const SOURCE_ORDER: Record<string, number> = { inferred: 0, declared: 1, probed: 2 };

/**
 * Overlay `facts` onto `card`. A fact never downgrades a higher-trust source:
 * probed > declared > inferred. Mutates and returns `card` (Python parity).
 */
export function mergeFacts(card: Card, facts: CardFacts): Card {
  for (const [operation, record] of Object.entries(facts.operations ?? {})) {
    const old = card.operations[operation];
    if (
      old &&
      (SOURCE_ORDER[old.source] ?? 0) > (SOURCE_ORDER[record.source] ?? 0) &&
      old.supported !== null &&
      old.supported !== undefined
    ) {
      continue;
    }
    card.operations[operation] = { ...(old ?? {}), ...record } as CapabilityRecord;
  }
  for (const key of ["sizes", "text_rendering"] as const) {
    const incoming = facts[key];
    const current = (card[key] ?? {}) as unknown as Record<string, unknown>;
    if (
      incoming &&
      (SOURCE_ORDER[(current.source as string) ?? ""] ?? -1) <=
        (SOURCE_ORDER[(incoming.source as string) ?? ""] ?? 0)
    ) {
      (card as unknown as Record<string, unknown>)[key] = { ...current, ...incoming };
    }
  }
  for (const key of [
    "max_n",
    "output_formats",
    "latency_ms_p50",
    "measured_cost_usd",
    "quality",
  ] as const) {
    if (facts[key] !== undefined && facts[key] !== null) {
      (card as unknown as Record<string, unknown>)[key] = facts[key];
    }
  }
  if (facts.input) card.input = { ...card.input, ...facts.input };
  return card;
}

/** The ONLY projection that leaves the gateway. Allow-list, not deny-list. */
export function publicCard(card: Card): PublicCard {
  const operations: PublicCard["operations"] = {};
  for (const operation of OPERATIONS) {
    const record = card.operations[operation];
    if (record?.supported !== true) continue;
    const entry: { confidence: "verified" | "estimated"; max_inputs?: number; max_n?: number } = {
      confidence: record.source === "probed" ? "verified" : "estimated",
    };
    if (operation === "multi_image") entry.max_inputs = Number(record.max_inputs) || 2;
    if (operation === "variations") entry.max_n = Number(card.max_n) || 1;
    operations[operation] = entry;
  }
  const native = card.sizes?.native ?? [DEFAULT_SIZE];
  const sizes = [...(native.length > 0 ? native : [DEFAULT_SIZE])];
  const latency = card.latency_ms_p50;
  return {
    slug: card.slug,
    tags: [...(card.tags ?? [])],
    operations,
    sizes,
    aspect_ratios: [...(card.sizes?.aspect_ratios ?? [])],
    max_n: Number(card.max_n) || 1,
    input: {
      max_images: maxInputs(card),
      formats: [...(card.input?.formats ?? [])],
    },
    output_formats: [
      ...(card.output_formats && card.output_formats.length > 0
        ? card.output_formats
        : ["png"]),
    ],
    text_rendering: card.text_rendering?.level ?? "none",
    quality: card.quality ?? "med",
    speed:
      latency === null || latency === undefined
        ? "unknown"
        : latency <= 8000
          ? "fast"
          : latency <= 25000
            ? "medium"
            : "slow",
    latency_p50_s:
      latency === null || latency === undefined ? null : Math.round(latency / 1000),
    cost_tier: card.cost_tier ?? "med",
    verified: card.state === "probed",
  };
}

export function catalogHash(publicCards: PublicCard[]): string {
  const sorted = [...publicCards].sort((left, right) =>
    left.slug < right.slug ? -1 : left.slug > right.slug ? 1 : 0,
  );
  return createHash("sha256").update(stableJson(sorted, true)).digest("hex").slice(0, 32);
}

/**
 * Card for a backend constructed with explicit (sizes, edit) — old tests, old
 * configs. 'declared' because the operator stated it.
 */
export function legacyCard(model: string, sizes: string[], edit: boolean): Card {
  const card = defaultCard(model);
  card.state = "declared";
  card.operations.edit = cap(Boolean(edit), "declared", 0.9);
  card.sizes = {
    native: [...sizes],
    aspect_ratios: [...new Set(sizes.map(ratioOf).filter((ratio): ratio is string => ratio !== null))].sort(),
    source: "declared",
    confidence: 0.9,
  };
  card.input.max_images = edit ? 1 : 0;
  return finalize(card);
}

export function clone(card: Card): Card {
  return structuredClone(card);
}
