import { ALIAS, DEFAULT_SIZE, SIZE_RE, maxInputs, supports, type Card } from "./capabilities.js";

/**
 * Port of server/images/routing.py — capability-based image backend selection.
 * Pure functions, no I/O.
 *
 * pickBackends hard-filters by what the task REQUIRES (operation, size/ratio,
 * mask, input count, transparency) and then scores what is left by preference
 * (quality | speed | cost | balanced) and text-rendering need. Models in
 * capacity cooldown are skipped, never ranked.
 */

export const PREFERENCES = ["balanced", "quality", "speed", "cost"] as const;
export type Preference = (typeof PREFERENCES)[number];

export const TASK_OPERATIONS = [
  "generate",
  "edit",
  "inpaint",
  "outpaint",
  "reference_style",
  "multi_image",
  "remove_background",
  "upscale",
  "variations",
] as const;

const COST_SCORE: Record<string, number> = { low: 0.0, med: 0.5, high: 1.0 };
const QUALITY_SCORE: Record<string, number> = { low: 0.0, med: 0.5, high: 1.0 };
const TEXT_SCORE: Record<string, number> = { none: 0.0, ok: 0.5, good: 1.0 };

export interface Task {
  operation: string;
  size: string | null;
  aspect_ratio: string | null;
  /** Input images, including the primary image. */
  n_inputs: number;
  mask: boolean;
  transparent: boolean;
  text_rendering: boolean;
  preference: Preference;
}

/** Capability keys the card must have as supported. */
export function needs(task: Task): string[] {
  const keys: string[] = [];
  const operation = task.operation;
  keys.push(operation === "generate" ? "generate" : "edit");
  if (
    [
      "inpaint",
      "outpaint",
      "reference_style",
      "multi_image",
      "remove_background",
      "upscale",
      "variations",
    ].includes(operation)
  ) {
    keys.push(operation);
  }
  if (task.mask && !keys.includes("inpaint")) keys.push("inpaint");
  if (task.n_inputs > 1 && !keys.includes("multi_image")) keys.push("multi_image");
  if (task.transparent && !keys.includes("transparent_output")) {
    keys.push("transparent_output");
  }
  return keys;
}

/** Why `card` cannot serve `task` (empty list = it can). */
export function missing(card: Card, task: Task): string[] {
  const reasons = needs(task).filter((operation) => !supports(card, operation));
  if (card.priced === false) reasons.push("unpriced"); // no LiteLLM price: never settle
  if (
    task.operation !== "generate" &&
    task.transparent &&
    card.edit_transport === "direct" &&
    !reasons.includes("transparent_output")
  ) {
    // The provider's edit contract has no background control.
    reasons.push("transparent_output");
  }
  const sizes = card.sizes?.native?.length ? card.sizes.native : [DEFAULT_SIZE];
  if (task.size && !sizes.includes(task.size)) reasons.push(`size:${task.size}`);
  if (task.aspect_ratio) {
    const ratios = card.sizes?.aspect_ratios ?? [];
    if (!ratios.includes(task.aspect_ratio)) {
      reasons.push(`aspect_ratio:${task.aspect_ratio}`);
    }
  }
  if (
    task.n_inputs > Math.max(maxInputs(card), 0) &&
    task.operation !== "generate" &&
    reasons.length === 0
  ) {
    reasons.push(`inputs:${task.n_inputs}`);
  }
  return reasons;
}

/** routing.py score(): the weight tables are verbatim. */
export function score(card: Card, task: Task): number {
  const cost = COST_SCORE[card.cost_tier ?? "med"] ?? 0.5;
  const quality = QUALITY_SCORE[card.quality ?? "med"] ?? 0.5;
  const latency = card.latency_ms_p50;
  const speed =
    latency === null || latency === undefined
      ? 0.5
      : Math.max(0.0, 1.0 - Math.min(latency, 60000) / 60000);
  const text = TEXT_SCORE[card.text_rendering?.level ?? "none"] ?? 0.0;
  const weights: Record<Preference, [number, number, number]> = {
    balanced: [1.0, 1.0, 1.0],
    quality: [3.0, 0.5, 0.3],
    speed: [0.4, 3.0, 0.4],
    cost: [0.3, 0.4, 3.0],
  };
  const [qualityWeight, speedWeight, costWeight] = weights[task.preference];
  let total =
    qualityWeight * quality + speedWeight * speed + costWeight * (1.0 - cost);
  if (task.text_rendering) total += 3.0 * text; // a need, not a taste
  // Verified cards beat guessed ones when otherwise close.
  if (card.state === "probed") total += 0.15;
  return total;
}

/** Ordered candidate cards: capable, available, best-first. Deterministic. */
export function pickBackends(
  task: Task,
  cards: Card[],
  unavailable?: (model: string) => boolean,
): Card[] {
  return cards
    .map((card, index) => ({ card, index, value: score(card, task) }))
    .filter(
      (entry) =>
        missing(entry.card, task).length === 0 &&
        !(unavailable?.(entry.card.model) ?? false),
    )
    .sort((left, right) => right.value - left.value || left.index - right.index)
    .map((entry) => entry.card);
}

/** Slugs able to do the task regardless of cooldown (for 422 bodies). */
export function alternatives(task: Task, cards: Card[]): string[] {
  return pickBackends(task, cards).map((card) => card.slug);
}

/** 'ovid-image' -> null (auto); 'ovid-image:img-xxxxxx' -> slug; else error. */
export function parseModel(value: unknown): string | null {
  if (value === ALIAS) return null;
  if (typeof value === "string" && new RegExp(`^${ALIAS}:[A-Za-z0-9_-]{3,40}$`).test(value)) {
    return value;
  }
  throw new Error("model");
}

export function normalizeSize(size: unknown): string {
  if (typeof size !== "string" || !SIZE_RE.test(size)) throw new Error("size");
  return size;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Python truthiness for the request fields routing.py tests with `or`/`if`. */
function pyTruthy(value: unknown): boolean {
  if (value === null || value === undefined || value === false || value === 0 || value === "") {
    return false;
  }
  if (Array.isArray(value)) return value.length > 0;
  if (isPlainObject(value)) return Object.keys(value).length > 0;
  return true;
}

const REQUIREMENTS = new Set([
  "operation",
  "aspect_ratio",
  "transparent_background",
  "text_rendering",
]);
const ASPECT_RATIO_RE = /^[1-9][0-9]?:[1-9][0-9]?$/;

/** Build a Task from a validated execute body. Throws on bad input. */
export function taskFromRequest(
  operation: "generate" | "edit",
  body: Record<string, unknown>,
): Task {
  if (!isPlainObject(body)) throw new Error("body");
  const rawRequirements = body.requirements;
  const req: Record<string, unknown> = !pyTruthy(rawRequirements)
    ? {}
    : isPlainObject(rawRequirements)
      ? rawRequirements
      : (() => {
          throw new Error("requirements");
        })();
  for (const key of Object.keys(req)) {
    if (!REQUIREMENTS.has(key)) throw new Error("requirements");
  }
  const preference = body.preference === undefined ? "balanced" : body.preference;
  if (
    typeof preference !== "string" ||
    !(PREFERENCES as readonly string[]).includes(preference)
  ) {
    throw new Error("preference");
  }
  let op: unknown = pyTruthy(req.operation) ? req.operation : operation;
  if (
    typeof op !== "string" ||
    !(TASK_OPERATIONS as readonly string[]).includes(op) ||
    (operation === "generate" && op !== "generate" && op !== "variations") ||
    (operation === "edit" && op === "generate")
  ) {
    throw new Error("operation");
  }
  let operationValue = op;
  const mask = pyTruthy(body.mask);
  if (mask && operationValue === "edit") operationValue = "inpaint";
  const rawExtra = pyTruthy(body.images) ? body.images : [];
  if (!Array.isArray(rawExtra) || rawExtra.length > 8) throw new Error("images");
  const nInputs = (pyTruthy(body.image) ? 1 : 0) + rawExtra.length;
  if (nInputs > 1 && operationValue === "edit") operationValue = "multi_image";
  const ratio = req.aspect_ratio;
  if (
    ratio !== undefined &&
    ratio !== null &&
    !(typeof ratio === "string" && ASPECT_RATIO_RE.test(ratio))
  ) {
    throw new Error("aspect_ratio");
  }
  const size = pyTruthy(body.size) ? normalizeSize(body.size) : null;
  return {
    operation: operationValue,
    size,
    aspect_ratio: typeof ratio === "string" ? ratio : null,
    n_inputs: nInputs,
    mask,
    transparent: pyTruthy(req.transparent_background),
    text_rendering: pyTruthy(req.text_rendering),
    preference: preference as Preference,
  };
}
