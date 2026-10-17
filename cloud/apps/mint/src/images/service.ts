import { createHash } from "node:crypto";
import { discounted, money, type Money } from "@ovid/money";
import { determineCost, type Prices } from "./costing.js";
import type { DirectEdit } from "./directEdit.js";
import type { ImageLedger } from "./ledger.js";
import {
  CAPACITY_RETRY_DEFAULT,
  IMAGE_ALIAS,
  ImageError,
  SIZES,
  capacityRetrySeconds,
  type Receipt,
} from "./types.js";
import { MAX_BYTES, validateImage } from "./validateImage.js";

/**
 * Port of deploy/images_gateway.py LiteLLMImageService.execute.
 *
 * Pipeline: validate -> route (Task 14 supplies the card/routing hooks) ->
 * ledger.begin(discounted(MAX_UPSTREAM)) -> per candidate (cooldown skip,
 * direct-vs-LiteLLM forward, verified pre-dispatch refusal -> continue,
 * anything ambiguous -> unknown/409) -> cost determination -> settle.
 *
 * Task 14 has not landed in this wave, so this module ships deterministic
 * legacy cards/routing as the DEFAULT implementation behind the same
 * `routing`/`cards` seams Task 14 will inject.
 */

export const IMAGE_BODY_LIMIT = Math.floor((MAX_BYTES * 4) / 3) + 65536;

const PRE_PROVIDER_REFUSAL_CODES = new Set([
  "not_an_image_model",
  "unsupported_modality",
  "unsupported_n",
]);

const COST_HEADER_KEYS = ["x-litellm-response-cost"];

export interface ImageCard {
  model: string;
  slug: string;
  sizes: { native: string[] };
  operations: Record<string, { supported?: boolean; source?: string }>;
  edit_transport?: string | null;
  priced?: boolean;
  aspect_ratios?: string[];
  cost_tier?: "low" | "med" | "high" | string;
  quality?: "low" | "med" | "high" | string;
  speed?: "fast" | "medium" | "slow" | string;
  text_rendering?: string;
  latency_p50_s?: number;
  state?: string;
  max_inputs?: number;
}

export interface ImageBackend {
  model: string;
  sizes: readonly string[];
  edit: boolean;
  card?: ImageCard;
  params?: Record<string, unknown>;
}

export interface ImageTask {
  operation: string;
  size: string | null;
  aspect_ratio: string | null;
  n_inputs: number;
  mask: boolean;
  transparent: boolean;
  text_rendering: boolean;
  preference: "balanced" | "quality" | "speed" | "cost";
}

export interface RoutingHooks {
  parseModel?(value: unknown): string | null;
  taskFromRequest?(operation: "generate" | "edit", body: Record<string, unknown>): ImageTask;
  missing?(card: ImageCard, task: ImageTask): string[];
  pickBackends?(
    task: ImageTask,
    cards: ImageCard[],
    unavailable?: (model: string) => boolean,
  ): ImageCard[];
  alternatives?(task: ImageTask, cards: ImageCard[]): string[];
  publicCard?(card: ImageCard): Record<string, unknown>;
  catalogHash?(cards: Record<string, unknown>[]): string;
}

export interface ImageServiceDeps {
  ledger: ImageLedger;
  backends: () => ImageBackend[] | Promise<ImageBackend[]>;
  /** Task 14 card source; when absent legacy cards are derived from backends. */
  cards?: () => ImageCard[] | Promise<ImageCard[]>;
  directEdit?: DirectEdit | null;
  fetchImpl?: typeof fetch;
  litellmBaseUrl: string;
  maxUpstreamCost: Money;
  priceBook?: { get(model: string): Promise<Prices | undefined> } | null;
  userKey(account: string): Promise<string | null>;
  userKeyId(account: string): Promise<string | null>;
  keySpend(keyId: string): Promise<number | null>;
  spendWait?: number;
  spendPoll?: number;
  routing?: RoutingHooks;
}

export interface CatalogBody {
  model: string;
  operations: Record<string, string[]>;
  availability: "unknown";
  schema: 2;
  catalog_hash: string;
  models: Record<string, unknown>[];
}

interface UpstreamResponse {
  status: number;
  headers: Record<string, string>;
  json(): Promise<unknown>;
}

interface ForwardOptions {
  operation: "generate" | "edit";
  prompt: string;
  size: string;
  imageB64: string | null;
  imageMime: string | null;
  mask: Buffer | null;
  extra: { data: Buffer; mime: string }[];
  transparent: boolean;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Deterministic JSON with sorted keys (Python json.dumps sort_keys). */
function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const object = value as Record<string, unknown>;
  const keys = Object.keys(object)
    .filter((key) => object[key] !== undefined)
    .sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${stableStringify(object[key])}`).join(",")}}`;
}

/** service.py _data_url(): strict image/png|jpeg|webp base64 data URL. */
function dataUrl(value: unknown): { b64: string; mime: string } {
  if (typeof value !== "string") throw new ImageError(400, "invalid_image");
  const match = /^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$/.exec(value);
  if (match === null || match[0] !== value) throw new ImageError(400, "invalid_image");
  return { b64: match[2]!, mime: match[1]! };
}

function supports(card: ImageCard, operation: string): boolean {
  return card.operations[operation]?.supported === true;
}

export function slugFor(model: string): string {
  return `ovid-image:img-${createHash("sha256").update(`ovid-slug|${model}`).digest("hex").slice(0, 6)}`;
}

export function legacyCard(backend: ImageBackend): ImageCard {
  const sizes = backend.sizes.length > 0 ? [...backend.sizes] : ["1024x1024"];
  return {
    model: backend.model,
    slug: slugFor(backend.model),
    sizes: { native: sizes },
    operations: {
      generate: { supported: true, source: "declared" },
      edit: { supported: backend.edit === true, source: "declared" },
    },
    edit_transport: backend.card?.edit_transport ?? null,
    priced: backend.card?.priced,
  };
}

export function parseModel(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (value === IMAGE_ALIAS) return null;
  if (typeof value === "string" && /^ovid-image:img-[A-Za-z0-9]{6}$/.test(value)) return value;
  throw new Error("invalid model");
}

const REQUIREMENTS = new Set(["aspect_ratio", "transparent_background", "text_rendering"]);
const PREFERENCES = new Set(["balanced", "quality", "speed", "cost"]);

export function taskFromRequest(
  operation: "generate" | "edit",
  body: Record<string, unknown>,
): ImageTask {
  if (operation !== "generate" && operation !== "edit") throw new Error("invalid operation");
  if (!isPlainObject(body)) throw new Error("invalid body");

  const preference = body.preference ?? "balanced";
  if (typeof preference !== "string" || !PREFERENCES.has(preference)) throw new Error("invalid preference");

  let aspectRatio: string | null = null;
  let transparent = false;
  let textRendering = false;
  if (body.requirements !== undefined && body.requirements !== null) {
    if (!isPlainObject(body.requirements)) throw new Error("invalid requirements");
    for (const key of Object.keys(body.requirements)) {
      if (!REQUIREMENTS.has(key)) throw new Error("invalid requirement");
    }
    const ratio = body.requirements.aspect_ratio;
    if (ratio !== undefined && (typeof ratio !== "string" || !/^\d{1,2}:\d{1,2}$/.test(ratio))) {
      throw new Error("invalid aspect ratio");
    }
    aspectRatio = typeof ratio === "string" ? ratio : null;
    transparent = body.requirements.transparent_background === true;
    textRendering = body.requirements.text_rendering === true;
  }

  const images = body.images;
  if (images !== undefined) {
    if (!Array.isArray(images)) throw new Error("invalid images");
    if (images.length > 8) throw new Error("too many images");
  }
  const mask = operation === "edit" && body.mask !== undefined && body.mask !== null;
  const extra = Array.isArray(images) ? images.length : 0;

  return {
    operation: mask ? "inpaint" : extra > 0 ? "multi_image" : operation,
    size: typeof body.size === "string" ? body.size : null,
    aspect_ratio: aspectRatio,
    n_inputs: 1 + extra,
    mask,
    transparent,
    text_rendering: textRendering,
    preference: preference as ImageTask["preference"],
  };
}

export function missing(card: ImageCard, task: ImageTask): string[] {
  const out: string[] = [];
  if (!supports(card, "generate")) out.push("generate");
  if (
    (task.operation === "edit" || task.operation === "inpaint" || task.operation === "multi_image") &&
    !supports(card, "edit")
  ) {
    out.push("edit");
  }
  if (task.operation === "inpaint" && !supports(card, "inpaint")) out.push("inpaint");
  if (task.operation === "multi_image" && !supports(card, "multi_image")) out.push("multi_image");
  if (task.transparent && !supports(card, "transparent_output")) out.push("transparent_output");
  if (task.size !== null && !card.sizes.native.includes(task.size)) out.push("size");
  if (
    task.aspect_ratio !== null &&
    Array.isArray(card.aspect_ratios) &&
    card.aspect_ratios.length > 0 &&
    !card.aspect_ratios.includes(task.aspect_ratio)
  ) {
    out.push("aspect_ratio");
  }
  if (card.priced === false) out.push("unpriced");
  return out;
}

function rank(value: string | undefined, order: string[]): number {
  const index = value === undefined ? -1 : order.indexOf(value);
  return index < 0 ? 0 : order.length - index;
}

export function score(card: ImageCard, task: ImageTask): number {
  let total = 0;
  if (task.preference === "cost") total += rank(card.cost_tier, ["low", "med", "high"]);
  if (task.preference === "speed") total += rank(card.speed, ["fast", "medium", "slow"]);
  if (task.preference === "quality") total += rank(card.quality, ["high", "med", "low"]);
  if (card.state === "probed") total += 0.15;
  if (task.text_rendering) total += 3 * (card.text_rendering === "good" ? 1 : 0);
  return total;
}

export function pickBackends(
  task: ImageTask,
  cards: ImageCard[],
  unavailable?: (model: string) => boolean,
): ImageCard[] {
  return cards
    .map((card, index) => ({ card, index, value: score(card, task) }))
    .filter(
      (entry) =>
        missing(entry.card, task).length === 0 && !(unavailable?.(entry.card.model) ?? false),
    )
    .sort((left, right) => right.value - left.value || left.index - right.index)
    .map((entry) => entry.card);
}

export function alternatives(task: ImageTask, cards: ImageCard[]): string[] {
  return pickBackends(task, cards).map((card) => card.slug);
}

export function publicCard(card: ImageCard): Record<string, unknown> {
  const operations = Object.keys(card.operations).filter((operation) => supports(card, operation));
  return {
    slug: card.slug,
    operations,
    sizes: [...card.sizes.native],
    aspect_ratios: card.aspect_ratios ?? [],
    max_n: 1,
    input: { max_images: card.max_inputs ?? 1, formats: ["png", "jpeg", "webp"] },
    output_formats: ["png", "jpeg", "webp"],
    cost_tier: card.cost_tier ?? "med",
    quality: card.quality ?? "med",
    speed: card.speed ?? "medium",
    verified: card.state === "probed",
  };
}

export function catalogHash(cards: Record<string, unknown>[]): string {
  const sorted = [...cards].sort((left, right) =>
    String(left.slug ?? "").localeCompare(String(right.slug ?? "")),
  );
  return createHash("sha256").update(JSON.stringify(sorted)).digest("hex").slice(0, 32);
}

export class CapacityCooldowns {
  private readonly until = new Map<string, number>();

  constructor(private readonly clock: () => number) {}

  retryAfter(model: string): number {
    const now = this.clock();
    for (const [name, expires] of [...this.until.entries()]) {
      if (expires <= now) this.until.delete(name);
    }
    const expires = this.until.get(model);
    return expires === undefined ? 0 : Math.max(1, Math.ceil(expires - now));
  }

  refused(model: string, seconds?: unknown): void {
    const until = this.clock() + capacityRetrySeconds(seconds);
    const existing = this.until.get(model);
    this.until.delete(model);
    this.until.set(model, Math.max(until, existing ?? until));
    while (this.until.size > 256) {
      const oldest = this.until.keys().next().value;
      if (oldest === undefined) break;
      this.until.delete(oldest);
    }
  }
}

async function isCapacityRejected(response: UpstreamResponse, model: string): Promise<boolean> {
  if (response.status !== 503) return false;
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    return false;
  }
  if (!isPlainObject(body) || !isPlainObject(body.error)) return false;
  const error = body.error;
  if (error.type === "no_capacity" || error.code === "no_capacity") return true;
  if (typeof error.message !== "string" || error.message === "") return false;
  const firstLine = error.message.split(/\r?\n/, 1)[0]!;
  const pattern = new RegExp(
    "^(?:litellm\\.ServiceUnavailableError: )?(?:ServiceUnavailableError: )?" +
      "(?:(?:\\[OI\\]|[OI])Exception - )?no available provider for " +
      escapeRegExp(model) +
      " \\(all offers exhausted or in cooldown\\); try again shortly$",
  );
  return pattern.test(firstLine);
}

async function structuredErrorCode(response: UpstreamResponse): Promise<string | null> {
  try {
    const body = await response.json();
    if (!isPlainObject(body) || !isPlainObject(body.error)) return null;
    const code = body.error.code;
    return typeof code === "string" && code !== "" ? code : null;
  } catch {
    return null;
  }
}

function headersRecord(headers: Headers): Record<string, string> {
  const out: Record<string, string> = {};
  headers.forEach((value, key) => {
    out[key.toLowerCase()] = value;
  });
  return out;
}

export class LiteLlmImageService {
  private readonly clock: () => number;
  private readonly fetchImpl: typeof fetch;
  private readonly base: string;
  private readonly cooldown: CapacityCooldowns;

  constructor(
    private readonly deps: ImageServiceDeps,
    opts: { clock?: () => number } = {},
  ) {
    this.clock = opts.clock ?? (() => Date.now() / 1000);
    this.fetchImpl = deps.fetchImpl ?? fetch;
    this.base = deps.litellmBaseUrl.replace(/\/+$/, "");
    this.cooldown = new CapacityCooldowns(() => this.clock());
  }

  get cooldowns(): CapacityCooldowns {
    return this.cooldown;
  }

  /** Receipt/result reads are ledger reads, exactly like the Python mount. */
  get ledger(): ImageLedger {
    return this.deps.ledger;
  }

  private routing(): Required<Pick<RoutingHooks, "parseModel" | "taskFromRequest" | "missing" | "pickBackends" | "alternatives" | "publicCard" | "catalogHash">> {
    return {
      parseModel: this.deps.routing?.parseModel ?? parseModel,
      taskFromRequest: this.deps.routing?.taskFromRequest ?? taskFromRequest,
      missing: this.deps.routing?.missing ?? missing,
      pickBackends: this.deps.routing?.pickBackends ?? pickBackends,
      alternatives: this.deps.routing?.alternatives ?? alternatives,
      publicCard: this.deps.routing?.publicCard ?? publicCard,
      catalogHash: this.deps.routing?.catalogHash ?? catalogHash,
    };
  }

  async backends(): Promise<ImageBackend[]> {
    return this.deps.backends();
  }

  async cards(): Promise<ImageCard[]> {
    if (this.deps.cards !== undefined) return this.deps.cards();
    const backends = await this.backends();
    return backends.map((backend) => backend.card ?? legacyCard(backend));
  }

  /** Private backend ids that must never appear in a public projection. */
  async privateModelNames(): Promise<string[]> {
    const names = new Set<string>();
    for (const backend of await this.backends()) {
      names.add(backend.model);
      names.add(`openai/${backend.model}`);
      const slash = backend.model.indexOf("/");
      names.add(slash === -1 ? backend.model : backend.model.slice(slash + 1));
    }
    return [...names];
  }

  async catalog(): Promise<CatalogBody> {
    const routing = this.routing();
    const backends = await this.backends();
    const delays = backends.map((backend) => this.cooldown.retryAfter(backend.model));
    if (delays.length > 0 && delays.every((delay) => delay > 0)) {
      throw new ImageError(503, "image_capacity_unavailable", {
        retryAfterSeconds: Math.min(...delays),
      });
    }
    const publicCards = (await this.cards()).map((card) => routing.publicCard(card));
    const operations: Record<string, string[]> = {};
    for (const operation of ["generate", "edit"]) {
      const sizes = new Set<string>();
      for (const card of publicCards) {
        const advertised = Array.isArray(card.operations) ? (card.operations as unknown[]) : [];
        if (!advertised.includes(operation)) continue;
        for (const size of (card.sizes as string[] | undefined) ?? []) sizes.add(size);
      }
      operations[operation] = [...sizes].sort();
    }
    return {
      model: IMAGE_ALIAS,
      operations,
      availability: "unknown",
      schema: 2,
      catalog_hash: routing.catalogHash(publicCards),
      models: publicCards,
    };
  }

  private async readSpend(keyId: string): Promise<number | null> {
    try {
      return await this.deps.keySpend(keyId);
    } catch {
      return null;
    }
  }

  async execute(
    account: string,
    request: string,
    operation: "generate" | "edit",
    body: Record<string, unknown>,
    budget: Money,
    opts: { budgetWindow?: string } = {},
  ): Promise<Record<string, unknown>> {
    const routing = this.routing();
    if (typeof request !== "string" || !/^[A-Za-z0-9_.:-]{8,128}$/.test(request)) {
      throw new ImageError(400, "invalid_request_id");
    }
    if ((operation !== "generate" && operation !== "edit") || !isPlainObject(body)) {
      throw new ImageError(400, "invalid_image_request");
    }
    const allowed = new Set(["model", "prompt", "size", "requirements", "preference"]);
    if (operation === "edit") {
      allowed.add("image");
      allowed.add("mask");
      allowed.add("images");
    }
    if (Object.keys(body).some((key) => !allowed.has(key))) {
      throw new ImageError(400, "invalid_image_request");
    }

    let slug: string | null;
    let task: ImageTask;
    try {
      slug = routing.parseModel(body.model);
      task = routing.taskFromRequest(operation, body);
    } catch {
      throw new ImageError(400, "invalid_image_request");
    }

    const prompt = body.prompt;
    const size = body.size === undefined ? "1024x1024" : body.size;
    if (typeof prompt !== "string" || prompt.trim() === "" || prompt.length > 8000) {
      throw new ImageError(400, "invalid_image_request");
    }
    if (
      typeof size !== "string" ||
      (!(SIZES as readonly string[]).includes(size) && slug === null)
    ) {
      throw new ImageError(400, "invalid_image_request");
    }

    let imageB64: string | null = null;
    let imageMime: string | null = null;
    let maskRaw: Buffer | null = null;
    const extra: { data: Buffer; mime: string }[] = [];
    if (operation === "edit") {
      const image = dataUrl(body.image);
      imageB64 = image.b64;
      imageMime = validateImage(image.b64, image.mime);
      if (body.mask !== undefined && body.mask !== null) {
        const mask = dataUrl(body.mask);
        validateImage(mask.b64, mask.mime);
        maskRaw = Buffer.from(mask.b64, "base64");
      }
      for (const value of Array.isArray(body.images) ? body.images : []) {
        const item = dataUrl(value);
        validateImage(item.b64, item.mime);
        extra.push({ data: Buffer.from(item.b64, "base64"), mime: item.mime });
      }
    }

    const cards = await this.cards();
    const backends = await this.backends();
    let ranked: ImageCard[];
    if (slug !== null) {
      const chosen = cards.find((card) => card.slug === slug);
      const unsupported = chosen === undefined ? [] : routing.missing(chosen, task);
      if (chosen === undefined || unsupported.length > 0) {
        throw new ImageError(422, "unsupported_image_operation", {
          detail: {
            model: slug,
            alternatives: routing.alternatives(task, cards),
            ...(chosen === undefined ? { reason: "unknown_model" } : { unsupported }),
          },
        });
      }
      ranked = [chosen];
    } else {
      ranked = routing.pickBackends(task, cards);
      if (ranked.length === 0) {
        const unpriced = cards.filter(
          (card) =>
            card.priced === false &&
            routing.missing(card, task).length === 1 &&
            routing.missing(card, task)[0] === "unpriced",
        );
        throw new ImageError(422, "unsupported_image_operation", {
          detail: {
            alternatives: [],
            ...(unpriced.length > 0 ? { reason: "no_priced_model" } : {}),
          },
        });
      }
    }

    const byModel = new Map(backends.map((backend) => [backend.model, backend]));
    const candidates = ranked
      .map((card) => byModel.get(card.model))
      .filter((backend): backend is ImageBackend => backend !== undefined);
    const slugs = new Map(ranked.map((card) => [card.model, card.slug]));
    if (candidates.length === 0) throw new ImageError(503, "image_unavailable");

    const fingerprint = createHash("sha256")
      .update(stableStringify([operation, body]))
      .digest("hex");
    const replay = await this.deps.ledger.begin(
      account,
      request,
      fingerprint,
      discounted(this.deps.maxUpstreamCost),
      budget,
      opts.budgetWindow ?? "default",
    );
    if (replay !== null) return replay;

    const key = await this.deps.userKey(account);
    if (key === null || key === "") throw new ImageError(401, "sign_in_required");
    const keyId = await this.deps.userKeyId(account);

    let lastStatus: number | null = null;
    let allCapacity = true;
    for (const backend of candidates) {
      // A deletion committed during an explicit refusal must fence the next
      // backend too, not just initial admission and late settlement.
      await this.deps.ledger.receipt(account, request);
      if (this.cooldown.retryAfter(backend.model) > 0) continue;

      const card = ranked.find((entry) => entry.model === backend.model)!;
      const direct =
        operation === "edit" &&
        card.edit_transport === "direct" &&
        this.deps.directEdit !== null &&
        this.deps.directEdit !== undefined &&
        this.deps.directEdit.hasKey;
      const spendBefore = keyId !== null && !direct ? await this.readSpend(keyId) : null;

      let response: UpstreamResponse;
      try {
        // images_gateway.py: req_size = task.size or card native[0]. An
        // omitted size means "let the selected card pick its first native
        // size", not a hardcoded 1024x1024.
        const requestSize = task.size ?? card.sizes.native[0] ?? "1024x1024";
        response = await this.forward(
          key,
          backend,
          card,
          {
            operation,
            prompt,
            size: requestSize,
            imageB64,
            imageMime,
            mask: maskRaw,
            extra,
            transparent: task.transparent || task.operation === "remove_background",
          },
          direct,
        );
      } catch (err) {
        throw await this.unknown(account, request, fingerprint);
      }

      if (await isCapacityRejected(response, backend.model)) {
        lastStatus = 503;
        this.cooldown.refused(backend.model, response.headers["retry-after"]);
        continue;
      }
      if (response.status === 400) {
        const code = await structuredErrorCode(response);
        if (code !== null && PRE_PROVIDER_REFUSAL_CODES.has(code)) {
          lastStatus = 400;
          allCapacity = false;
          continue;
        }
      }
      if (response.status !== 200) {
        throw await this.unknown(account, request, fingerprint);
      }

      let data: unknown;
      let mime: string;
      let result: Record<string, unknown>;
      try {
        data = await response.json();
        const rows = isPlainObject(data) && Array.isArray(data.data) ? data.data : null;
        if (rows === null || rows.length !== 1 || !isPlainObject(rows[0])) throw new Error("bad rows");
        const encoded = rows[0].b64_json;
        mime = validateImage(encoded);
        result = {
          model: IMAGE_ALIAS,
          data: [{ b64_json: encoded, mime_type: mime }],
          model_slug: slugs.get(backend.model),
        };
      } catch (err) {
        // A successful upstream response may already have been billed: keep
        // the reservation for reconciliation; never retry it.
        throw await this.unknown(account, request, fingerprint);
      }

      let actual: Money | null;
      if (direct) {
        actual = this.deps.directEdit!.settlementCost(data, this.deps.maxUpstreamCost);
      } else {
        const headers: Record<string, string> = {};
        for (const name of COST_HEADER_KEYS) {
          const value = response.headers[name];
          if (value !== undefined) headers[name] = value;
        }
        const determined = await determineCost({
          headers,
          usage: isPlainObject(data) ? data.usage : undefined,
          prices:
            this.deps.priceBook === null || this.deps.priceBook === undefined
              ? undefined
              : () => this.deps.priceBook!.get(backend.model),
          spendBefore,
          spendRead: keyId === null ? null : () => this.readSpend(keyId),
          spendWait: this.deps.spendWait ?? 1.5,
          spendPoll: this.deps.spendPoll ?? 1.5,
          bound: this.deps.maxUpstreamCost,
        });
        actual = determined.cost;
      }
      if (actual === null || actual.lessThanOrEqualTo(0)) {
        // No dashboard price recorded the spend: keep the reservation.
        throw await this.unknown(account, request, fingerprint);
      }
      try {
        return await this.deps.ledger.settle(
          account,
          request,
          actual,
          result,
          slugs.get(backend.model) ?? null,
        );
      } catch (error) {
        if (error instanceof ImageError) throw error;
        throw await this.unknown(account, request, fingerprint);
      }
    }

    await this.deps.ledger.fail(account, request);
    if (allCapacity) {
      const delays = candidates.map((backend) => this.cooldown.retryAfter(backend.model));
      throw new ImageError(503, "image_capacity_unavailable", {
        retryAfterSeconds: Math.max(1, Math.min(...delays)),
        receipt: await this.deps.ledger.receipt(account, request),
      });
    }
    throw new ImageError(lastStatus === 503 || lastStatus === null ? 503 : 502, "image_unavailable", {
      receipt: await this.deps.ledger.receipt(account, request),
    });
  }

  private async forward(
    key: string,
    backend: ImageBackend,
    card: ImageCard,
    options: ForwardOptions,
    direct: boolean,
  ): Promise<UpstreamResponse> {
    if (direct) {
      if (options.mask !== null || options.extra.length > 0 || options.transparent) {
        throw new ImageError(422, "unsupported_image_operation");
      }
      return this.deps.directEdit!.post(
        backend.params ?? {},
        options.prompt,
        options.size,
        `data:${options.imageMime};base64,${options.imageB64}`,
      );
    }

    const headers: Record<string, string> = { Authorization: `Bearer ${key}` };
    let response: Response;
    if (options.operation === "generate") {
      const body: Record<string, unknown> = {
        model: backend.model,
        prompt: options.prompt,
        size: options.size,
        n: 1,
        response_format: "b64_json",
      };
      if (options.transparent) body.background = "transparent";
      response = await this.fetchImpl(`${this.base}/v1/images/generations`, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify(body),
        redirect: "manual",
      });
    } else {
      const form = new FormData();
      form.append("model", backend.model);
      form.append("prompt", options.prompt);
      form.append("size", options.size);
      form.append("n", "1");
      if (options.transparent) form.append("background", "transparent");
      const inputs = [
        { data: Buffer.from(options.imageB64 ?? "", "base64"), mime: options.imageMime ?? "image/png" },
        ...options.extra,
      ];
      const field = inputs.length > 1 ? "image[]" : "image";
      inputs.forEach((input, index) => {
        form.append(
          field,
          new Blob([new Uint8Array(input.data)], { type: input.mime }),
          index === 0 ? "image.png" : `image${index}.png`,
        );
      });
      if (options.mask !== null) {
        form.append(
          "mask",
          new Blob([new Uint8Array(options.mask)], { type: "image/png" }),
          "mask.png",
        );
      }
      response = await this.fetchImpl(`${this.base}/v1/images/edits`, {
        method: "POST",
        headers,
        body: form,
        redirect: "manual",
      });
    }
    return {
      status: response.status,
      headers: headersRecord(response.headers),
      json: () => response.json(),
    };
  }

  private async unknown(
    account: string,
    request: string,
    fingerprint: string,
  ): Promise<ImageError> {
    let receipt: Record<string, unknown> = {
      account_id: account,
      request_id: request,
      fingerprint,
      state: "unknown",
      charged: null,
    };
    try {
      await this.deps.ledger.unknown(account, request);
      receipt = { ...(await this.deps.ledger.receipt(account, request)) };
    } catch {
      // Even a failed status write cannot undo the durable admission.
    }
    return new ImageError(409, "image_request_pending", {
      receipt: receipt as unknown as Receipt,
    });
  }
}

export function createLiteLlmImageService(
  deps: ImageServiceDeps,
  opts: { clock?: () => number } = {},
): LiteLlmImageService {
  return new LiteLlmImageService(deps, opts);
}

export { CAPACITY_RETRY_DEFAULT };
