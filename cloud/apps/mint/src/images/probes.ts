import { deflateSync, inflateSync } from "node:zlib";
import { money, type Money } from "@ovid/money";
import {
  DEFAULT_SIZE,
  cap,
  clone,
  finalize,
  mergeFacts,
  ratioOf,
  type Card,
  type CardFacts,
} from "./capabilities.js";
import type { CardStore } from "./cardStore.js";
import { determineCost, normalizePrices, parseModelInfo } from "./costing.js";
import { defaultProbeSizes } from "./extraction.js";

/**
 * Port of server/images/probes.py — budgeted active capability probes, run
 * ONLY by the background worker.
 *
 * Never on a user request path. One probe run at a time (global lock), tiny
 * synthetic inputs, a hard per-probe and daily spend cap, and a pass/fail
 * result that distinguishes "unsupported" (the model refused the operation)
 * from "transient" (timeout, 429, 5xx — says nothing about the capability, so
 * the capability is left as it was).
 */

export const UNSUPPORTED = "unsupported";
export const TRANSIENT = "transient";
export const AUTH = "auth";
export const BUDGET = "budget";
export const INCONCLUSIVE = "inconclusive";
/** Provider ignored response_format=b64_json and returned URLs. */
export const URL_RESPONSE = "url_response";

export const WARNINGS: Record<string, string> = {
  [URL_RESPONSE]:
    "returns_urls: provider ignores response_format=b64_json and returns image URLs; the gateway never " +
    "fetches URLs, so this model is unusable until it supports b64_json",
  [AUTH]:
    "probe_auth: the provider rejected the credential; check the model api_key in LiteLLM",
  [BUDGET]:
    "probe_budget: provider or LiteLLM budget exhausted; top up, then POST /images/admin/reprobe",
  daily_budget:
    "probe_daily_budget: OVID_PROBE_DAILY_USD reached; probes resume when the 24h window frees up",
  per_probe_cap:
    "probe_per_probe_cap: a probe cost more than OVID_PROBE_MAX_USD; raise it or lower the model price",
  estimate_exceeds_cap:
    "probe_skipped: estimated probe cost exceeds OVID_PROBE_MAX_USD; raise it to probe this model",
};

const INCONCLUSIVE_WORDS = [
  "too small",
  "at least",
  "minimum",
  "dimension",
  "resolution too",
  "must be larger",
];
const BUDGET_WORDS = [
  "insufficient_quota",
  "insufficient quota",
  "insufficient credit",
  "insufficient funds",
  "billing",
  "exceeded your current quota",
  "out of credits",
  "payment required",
];
const POLICY_WORDS = [
  "content policy",
  "content_policy",
  "safety system",
  "moderation",
  "safety filter",
];
const UNSUPPORTED_WORDS = [
  "not support",
  "unsupported",
  "not available for",
  "invalid size",
  "unknown parameter",
  "unrecognized",
  "not a valid",
  "does not allow",
  "only supports",
];

const DIRECT_UNSUPPORTED_CODES = new Set(["not_an_image_model", "unsupported_modality"]);

export interface ProbeOutcome {
  ok: boolean;
  errorClass: string | null;
  latencyMs: number | null;
  costUsd: number | null;
  /** Decoded output image bytes. */
  images: Uint8Array[];
  costSource: string | null;
}

export interface ProbeParams {
  prompt: string;
  size: string;
  n?: number;
  background?: string;
  images?: Uint8Array[];
  mask?: Uint8Array;
  direct?: boolean;
  [extra: string]: unknown;
}

export interface ProbeTransport {
  call(model: string, kind: "generate" | "edit", params: ProbeParams): Promise<ProbeOutcome>;
  /** Flat direct-edit cost, when the transport knows it. */
  readonly editCost?: number | null;
}

export class ProbeBusy extends Error {
  constructor() {
    super("probe run already in progress");
    this.name = "ProbeBusy";
  }
}

// ── image helpers (PIL parity without a native image dependency) ────────────

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

let crcTable: Uint32Array | null = null;

function crc32(data: Uint8Array): number {
  if (crcTable === null) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n += 1) {
      let c = n;
      for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (const byte of data) crc = crcTable[(crc ^ byte) & 0xff]! ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type: string, data: Uint8Array): Buffer {
  const typeBytes = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBytes, Buffer.from(data)])), 0);
  return Buffer.concat([length, typeBytes, Buffer.from(data), crc]);
}

/**
 * probes.py synthetic_png(): a tiny solid PNG. The alpha variant has its left
 * half fully transparent (the same shape the Python PIL helper draws).
 */
export function syntheticPng(size = 64, alpha = false): Uint8Array {
  const channels = alpha ? 4 : 3;
  const stride = size * channels + 1;
  const raw = Buffer.alloc(stride * size);
  for (let y = 0; y < size; y += 1) {
    const row = y * stride;
    raw[row] = 0; // filter: none
    for (let x = 0; x < size; x += 1) {
      const offset = row + 1 + x * channels;
      if (alpha) {
        if (x < Math.floor(size / 2)) {
          raw[offset] = 0;
          raw[offset + 1] = 0;
          raw[offset + 2] = 0;
          raw[offset + 3] = 0;
        } else {
          raw[offset] = 255;
          raw[offset + 1] = 0;
          raw[offset + 2] = 0;
          raw[offset + 3] = 255;
        }
      } else {
        raw[offset] = 200;
        raw[offset + 1] = 60;
        raw[offset + 2] = 60;
      }
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = alpha ? 6 : 2; // RGBA / RGB
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;
  return Buffer.concat([
    PNG_SIGNATURE,
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

/** probes.py sniff_format(). */
export function sniffFormat(raw: Uint8Array): "png" | "jpeg" | "webp" | null {
  const bytes = Buffer.from(raw);
  if (bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return "png";
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "jpeg";
  }
  if (
    bytes.length >= 12 &&
    bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
    bytes.subarray(8, 12).toString("ascii") === "WEBP"
  ) {
    return "webp";
  }
  return null;
}

/** True when a PNG carries a real alpha band with any pixel below 255. */
export function hasAlpha(raw: Uint8Array): boolean {
  try {
    const bytes = Buffer.from(raw);
    if (!bytes.subarray(0, 8).equals(PNG_SIGNATURE)) return false;
    let offset = 8;
    let width = 0;
    let height = 0;
    let bitDepth = 8;
    let colorType = -1;
    const idat: Buffer[] = [];
    while (offset + 8 <= bytes.length) {
      const length = bytes.readUInt32BE(offset);
      const type = bytes.subarray(offset + 4, offset + 8).toString("ascii");
      const data = bytes.subarray(offset + 8, offset + 8 + length);
      if (type === "IHDR") {
        width = data.readUInt32BE(0);
        height = data.readUInt32BE(4);
        bitDepth = data[8]!;
        colorType = data[9]!;
      } else if (type === "IDAT") {
        idat.push(Buffer.from(data));
      } else if (type === "IEND") {
        break;
      }
      offset += 12 + length;
    }
    if (colorType !== 4 && colorType !== 6) return false;
    if (bitDepth !== 8) return false;
    const channels = colorType === 6 ? 4 : 2;
    const alphaIndex = channels - 1;
    const stride = width * channels;
    const inflated = inflateSync(Buffer.concat(idat));
    const previous = Buffer.alloc(stride);
    const current = Buffer.alloc(stride);
    for (let y = 0; y < height; y += 1) {
      const filter = inflated[y * (stride + 1)]!;
      const row = inflated.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
      for (let x = 0; x < stride; x += 1) {
        const left = x >= channels ? current[x - channels]! : 0;
        const up = previous[x]!;
        const upLeft = x >= channels ? previous[x - channels]! : 0;
        let value = row[x]!;
        if (filter === 1) value += left;
        else if (filter === 2) value += up;
        else if (filter === 3) value += Math.floor((left + up) / 2);
        else if (filter === 4) {
          const p = left + up - upLeft;
          const pa = Math.abs(p - left);
          const pb = Math.abs(p - up);
          const pc = Math.abs(p - upLeft);
          value += pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
        }
        current[x] = value & 0xff;
      }
      for (let x = 0; x < width; x += 1) {
        if (current[x * channels + alphaIndex]! < 255) return true;
      }
      current.copy(previous);
    }
    return false;
  } catch {
    return false;
  }
}

/** Python base64.b64decode(validate=True): alphabet + padding are strict. */
function decodeBase64Strict(value: string): Buffer | null {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    return null;
  }
  if (value.length % 4 !== 0) return null;
  try {
    return Buffer.from(value, "base64");
  } catch {
    return null;
  }
}

/**
 * Reply rows -> (images, error_class). URL replies and non-image payloads never
 * become card facts.
 */
export function decodeRows(rows: unknown): { images: Uint8Array[]; errorClass: string | null } {
  const images: Uint8Array[] = [];
  for (const row of Array.isArray(rows) ? rows : []) {
    if (typeof row !== "object" || row === null || Array.isArray(row)) {
      return { images: [], errorClass: TRANSIENT };
    }
    const record = row as Record<string, unknown>;
    if (!record.b64_json) {
      return { images: [], errorClass: record.url ? URL_RESPONSE : TRANSIENT };
    }
    if (typeof record.b64_json !== "string") {
      return { images: [], errorClass: INCONCLUSIVE };
    }
    const raw = decodeBase64Strict(record.b64_json);
    if (raw === null) return { images: [], errorClass: INCONCLUSIVE };
    if (sniffFormat(raw) === null) return { images: [], errorClass: INCONCLUSIVE };
    images.push(raw);
  }
  return { images, errorClass: null };
}

export interface DirectErrorResponse {
  json(): unknown;
  text: string;
}

/** Direct JSON edit probe verdict (only documented structured codes refute). */
export function classifyDirectError(status: number, response: DirectErrorResponse): string {
  let code: unknown = null;
  try {
    const body = response.json();
    if (typeof body === "object" && body !== null && !Array.isArray(body)) {
      const error = (body as Record<string, unknown>).error;
      if (typeof error === "object" && error !== null && !Array.isArray(error)) {
        code = (error as Record<string, unknown>).code;
      }
    }
  } catch {
    code = null;
  }
  if (status === 400 && typeof code === "string" && DIRECT_UNSUPPORTED_CODES.has(code)) {
    return UNSUPPORTED;
  }
  const verdict = classifyError(status, status === 400 ? "" : response.text.slice(0, 2000));
  return verdict === UNSUPPORTED ? INCONCLUSIVE : verdict;
}

/** probes.py classify_error(). */
export function classifyError(status: number, text = ""): string {
  const lowered = (text ?? "").toLowerCase();
  if (status === 401 || status === 403) return AUTH;
  if (
    status === 402 ||
    lowered.includes("budget") ||
    lowered.includes("max_budget") ||
    BUDGET_WORDS.some((word) => lowered.includes(word))
  ) {
    return BUDGET;
  }
  if (status === 400 || status === 422) {
    if (POLICY_WORDS.some((word) => lowered.includes(word))) return INCONCLUSIVE;
    if (INCONCLUSIVE_WORDS.some((word) => lowered.includes(word))) return INCONCLUSIVE;
  }
  if ([400, 404, 405, 415, 422, 501].includes(status)) return UNSUPPORTED;
  if (UNSUPPORTED_WORDS.some((word) => lowered.includes(word))) return UNSUPPORTED;
  return TRANSIENT;
}

// ── probe runner ────────────────────────────────────────────────────────────

export interface ProbeRunnerOptions {
  perProbeCap?: number;
  dailyCap?: number;
  maxSizes?: number;
  estimatedCost?: number;
  clock?: () => number;
}

export interface ProbeSummary {
  spent: Money;
  stop: string | null;
  incomplete: boolean;
  transient: boolean;
}

export interface ProbeRunResult extends ProbeSummary {
  card: Card;
}

function median(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? sorted[middle]!
    : (sorted[middle - 1]! + sorted[middle]!) / 2;
}

function round6(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

/** One probe run at a time across every runner in the process. */
let probeLock = false;

export class ProbeRunner {
  private readonly perProbeCap: Money;
  private readonly dailyCap: Money;
  private readonly maxSizes: number;
  private readonly estimatedCost: Money;
  private readonly clock: () => number;

  constructor(
    private readonly transport: ProbeTransport,
    private readonly store: CardStore,
    opts: ProbeRunnerOptions = {},
  ) {
    this.perProbeCap = money(opts.perProbeCap ?? 0.5);
    this.dailyCap = money(opts.dailyCap ?? 5.0);
    this.maxSizes = Math.trunc(opts.maxSizes ?? 4);
    this.estimatedCost = money(opts.estimatedCost ?? 0.05);
    this.clock = opts.clock ?? (() => Date.now() / 1000);
  }

  get perProbeCapUsd(): Money {
    return this.perProbeCap;
  }

  get dailyCapUsd(): Money {
    return this.dailyCap;
  }

  /**
   * Probe `card.model`; never raises on provider failure. Raises ProbeBusy
   * when another run is in progress.
   */
  async run(card: Card, facts: CardFacts = {}): Promise<ProbeRunResult> {
    if (probeLock) throw new ProbeBusy();
    probeLock = true;
    try {
      return await this.runLocked(card, facts);
    } finally {
      probeLock = false;
    }
  }

  private async runLocked(card: Card, facts: CardFacts): Promise<ProbeRunResult> {
    const model = card.model;
    const working = clone(card);
    const ctx = {
      spent: money(0),
      stop: null as string | null,
      results: [] as Card["probes"],
      latencies: [] as number[],
      costs: [] as number[],
      warnings: [] as string[],
      headerSeen: false,
      formats: [] as string[],
    };
    // Python truthiness: 0/undefined fall through to the stored card.
    const knownCost = facts.measured_cost_usd || card.measured_cost_usd || null;
    const known = knownCost !== null ? money(knownCost) : null;
    const estimated = known ?? this.estimatedCost;
    if (known !== null && known.greaterThan(this.perProbeCap)) {
      // LiteLLM already says a single call costs more than the per-probe cap.
      working.probe_warnings = [WARNINGS.estimate_exceeds_cap];
      working.probed_at = Math.trunc(this.clock());
      working.probe_stop = "estimate_exceeds_cap";
      finalize(working);
      return {
        card: working,
        spent: money(0),
        stop: "estimate_exceeds_cap",
        incomplete: true,
        transient: false,
      };
    }
    const dayStart = this.clock() - 24 * 3600;

    const attempt = async (
      name: string,
      kind: "generate" | "edit",
      params: ProbeParams,
    ): Promise<ProbeOutcome | null> => {
      if (ctx.stop !== null) return null;
      let estimateHere = estimated;
      if (params.direct) {
        const flat = this.transport.editCost;
        if (flat !== null && flat !== undefined && flat !== 0) {
          if (money(flat).greaterThan(this.perProbeCap)) return null;
          estimateHere = money(flat);
        }
      }
      const already = await this.store.spentSince(dayStart);
      if (already.plus(estimateHere).greaterThan(this.dailyCap)) {
        ctx.stop = "daily_budget";
        return null;
      }
      const out = await this.transport.call(model, kind, params);
      const cost =
        out.costUsd !== null && out.costUsd !== undefined
          ? money(out.costUsd)
          : out.ok
            ? estimateHere
            : money(0);
      ctx.spent = ctx.spent.plus(cost);
      await this.store.logProbe(
        model,
        name,
        out.ok,
        out.errorClass,
        out.latencyMs,
        cost,
      );
      ctx.results.push({
        probe: name,
        ok: out.ok,
        error_class: out.errorClass,
        latency_ms: out.latencyMs,
        cost_usd: round6(Number(cost.toString())),
        at: Math.trunc(this.clock()),
      });
      if (
        out.costUsd !== null &&
        out.costUsd !== undefined &&
        money(out.costUsd).greaterThan(this.perProbeCap)
      ) {
        ctx.stop = "per_probe_cap";
      }
      if (out.errorClass === AUTH || out.errorClass === BUDGET) ctx.stop = out.errorClass;
      if (out.errorClass === URL_RESPONSE) ctx.warnings.push(WARNINGS[URL_RESPONSE]!);
      if (out.costSource === "header") ctx.headerSeen = true;
      return out;
    };

    const verdict = (out: ProbeOutcome | null): boolean | null => {
      if (
        out === null ||
        out.errorClass === TRANSIENT ||
        out.errorClass === INCONCLUSIVE ||
        out.errorClass === AUTH ||
        out.errorClass === BUDGET
      ) {
        return null;
      }
      return out.ok;
    };

    const png = syntheticPng();
    const operations: Record<string, ReturnType<typeof cap>> = {};
    // 1+2: generate at the default size, then the other candidates (bounded).
    const candidates = defaultProbeSizes(facts, this.maxSizes);
    const passedSizes: string[] = [];
    const generateVerdicts: (boolean | null)[] = [];
    for (const size of candidates) {
      const out = await attempt(`generate:${size}`, "generate", {
        prompt: "a small red circle on white",
        size,
      });
      generateVerdicts.push(verdict(out));
      if (out !== null && out.ok) {
        for (const raw of out.images) {
          const format = sniffFormat(raw);
          if (format !== null) ctx.formats.push(format);
        }
        passedSizes.push(size);
        if (out.latencyMs !== null) ctx.latencies.push(out.latencyMs);
        if (out.costUsd) ctx.costs.push(out.costUsd);
      }
      if (ctx.stop !== null) break;
    }
    const generateOk =
      passedSizes.length > 0
        ? true
        : generateVerdicts.length > 0 && generateVerdicts.every((value) => value === false)
          ? false
          : null;
    if (generateOk !== null) operations.generate = cap(generateOk, "probed", 0.9);
    let sizesFact: CardFacts["sizes"] | null = null;
    if (passedSizes.length > 0 && !generateVerdicts.includes(null)) {
      sizesFact = {
        native: passedSizes,
        source: "probed",
        confidence: 0.9,
        aspect_ratios: [
          ...new Set(
            passedSizes.map(ratioOf).filter((ratio): ratio is string => ratio !== null),
          ),
        ].sort(),
      };
    } else if (passedSizes.length > 0) {
      // Some sizes inconclusive: keep the proven ones plus what static said.
      const knownSizes = [...(card.sizes?.native ?? [])];
      const native = [...passedSizes, ...knownSizes.filter((size) => !passedSizes.includes(size))];
      sizesFact = {
        native,
        source: "probed",
        confidence: 0.6,
        aspect_ratios: [
          ...new Set(native.map(ratioOf).filter((ratio): ratio is string => ratio !== null)),
        ].sort(),
      };
    }
    const size = passedSizes[0] ?? DEFAULT_SIZE;

    if (generateOk !== false) {
      // 3: edit
      const transport = card.edit_transport;
      const direct = transport === "direct";
      let editVerdict: boolean | null = null;
      if (transport !== "none") {
        const out = await attempt("edit", "edit", {
          prompt: "make the square blue",
          size,
          images: [png],
          direct,
        });
        editVerdict = verdict(out);
      }
      if (editVerdict !== null) operations.edit = cap(editVerdict, "probed", 0.9);
      if (editVerdict === false) {
        for (const dependent of [
          "inpaint",
          "outpaint",
          "multi_image",
          "reference_style",
          "remove_background",
        ]) {
          operations[dependent] = cap(false, "probed", 0.6);
        }
      } else if (editVerdict && !direct) {
        // Direct JSON edits have no mask/extra-image contract: nothing to probe.
        const inpaint = await attempt("inpaint", "edit", {
          prompt: "fill the transparent area with green",
          size,
          images: [png],
          mask: syntheticPng(64, true),
        });
        const inpaintVerdict = verdict(inpaint);
        if (inpaintVerdict !== null) {
          operations.inpaint = cap(inpaintVerdict, "probed", 0.85);
          operations.outpaint = cap(inpaintVerdict, "inferred", 0.5);
        }
        const multi = await attempt("multi_image", "edit", {
          prompt: "combine both images",
          size,
          images: [png, syntheticPng(64, true)],
        });
        const multiVerdict = verdict(multi);
        if (multiVerdict !== null) {
          operations.multi_image = cap(multiVerdict, "probed", 0.85, {
            max_inputs: multiVerdict ? 2 : 0,
          });
          operations.reference_style = cap(multiVerdict, "inferred", 0.5);
        }
      }
      // 4: transparent output
      const transparent = await attempt("transparent", "generate", {
        prompt: "a red circle, transparent background",
        size,
        background: "transparent",
      });
      if (transparent !== null && transparent.ok) {
        const alpha = transparent.images[0] !== undefined && hasAlpha(transparent.images[0]);
        operations.transparent_output = cap(alpha, "probed", 0.8);
        if (alpha && editVerdict && !direct) {
          operations.remove_background = cap(true, "inferred", 0.5);
        }
      } else if (verdict(transparent) === false) {
        operations.transparent_output = cap(false, "probed", 0.7);
      }
      // 5: variations (n=2)
      const variations = await attempt("variations", "generate", {
        prompt: "a red circle",
        size,
        n: 2,
      });
      if (variations !== null && variations.ok) {
        const many = variations.images.length >= 2;
        operations.variations = cap(many, "probed", 0.8, { max_n: many ? 2 : 1 });
      } else if (verdict(variations) === false) {
        operations.variations = cap(false, "probed", 0.7);
      }
      // 6: text-in-image smoke test (no OCR: a pass only proves it runs)
      await attempt("text", "generate", {
        prompt: 'A poster with the exact word "OVID" in large letters',
        size,
      });
    }

    const newFacts: CardFacts = { operations };
    const formats: string[] = [];
    for (const format of ctx.formats) if (!formats.includes(format)) formats.push(format);
    if (formats.length > 0) newFacts.output_formats = formats;
    if (sizesFact !== null) newFacts.sizes = sizesFact;
    if (ctx.latencies.length > 0) newFacts.latency_ms_p50 = Math.trunc(median(ctx.latencies));
    if (ctx.costs.length > 0) newFacts.measured_cost_usd = median(ctx.costs);
    if (operations.variations?.supported) newFacts.max_n = 2;
    mergeFacts(working, newFacts);
    // Probed values override even a higher-confidence static guess.
    for (const [operation, record] of Object.entries(operations)) {
      working.operations[operation] = {
        ...(working.operations[operation] ?? {}),
        ...record,
      };
    }
    const textPass = ctx.results.find((result) => result.probe === "text");
    if (
      textPass?.ok &&
      working.text_rendering?.source !== "inferred"
    ) {
      working.text_rendering = { level: "ok", source: "probed", confidence: 0.3 };
    }
    const core = ctx.results.filter(
      (result) => result.probe.startsWith("generate:") || result.probe === "edit",
    );
    const incomplete =
      ctx.stop !== null ||
      core.some(
        (result) =>
          result.error_class === TRANSIENT || result.error_class === INCONCLUSIVE,
      ) ||
      generateOk === null;
    working.probes = ctx.results;
    working.probed_at = Math.trunc(this.clock());
    working.state = incomplete || generateOk === false ? "inferred" : "probed";
    working.probe_stop = ctx.stop;
    if (ctx.headerSeen) working.cost_header_seen = true;
    if (ctx.stop !== null && WARNINGS[ctx.stop] !== undefined) {
      ctx.warnings.push(WARNINGS[ctx.stop]!);
    }
    working.probe_warnings = [...new Set(ctx.warnings)];
    finalize(working);
    return {
      card: working,
      spent: ctx.spent,
      stop: ctx.stop,
      incomplete,
      transient: ctx.results.some((result) => result.error_class === TRANSIENT),
    };
  }
}

// ── real LiteLLM transport ──────────────────────────────────────────────────

export interface ProbeHttpResponse {
  status: number;
  headers: Record<string, string>;
  text: string;
  json(): unknown;
}

export interface ProbeHttpRequest {
  headers?: Record<string, string>;
  params?: Record<string, string>;
  json?: Record<string, unknown>;
  form?: FormData;
}

export interface ProbeHttpClient {
  get(path: string, opts?: ProbeHttpRequest): Promise<ProbeHttpResponse>;
  post(path: string, opts?: ProbeHttpRequest): Promise<ProbeHttpResponse>;
  close(): void;
}

export interface DirectProbeEdit {
  enabled_for(params: Record<string, unknown> | null | undefined): boolean;
  post(
    params: Record<string, unknown> | null | undefined,
    prompt: string,
    size: string,
    imageDataUrl: string,
  ): Promise<{ status: number; headers: Record<string, string>; json(): Promise<unknown> }>;
  settlementCost(responseJson: unknown, bound: Money): Money;
  editCost?: number | null;
}

export interface LiteLLMProbeTransportOptions {
  masterKey?: string | null;
  timeout?: number;
  spendWait?: number;
  clientFactory?: (opts: {
    baseUrl: string;
    timeout: number;
    followRedirects: boolean;
  }) => ProbeHttpClient;
  direct?: DirectProbeEdit | null;
  paramsFor?: (model: string) => Record<string, unknown> | null;
}

class FetchProbeClient implements ProbeHttpClient {
  private readonly root: string;
  constructor(
    baseUrl: string,
    private readonly timeout: number,
    private readonly followRedirects: boolean,
  ) {
    this.root = baseUrl.replace(/\/+$/, "");
  }

  private async request(
    method: "GET" | "POST",
    path: string,
    opts: ProbeHttpRequest = {},
  ): Promise<ProbeHttpResponse> {
    const url = new URL(`${this.root}${path}`);
    for (const [key, value] of Object.entries(opts.params ?? {})) {
      url.searchParams.set(key, value);
    }
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    let body: BodyInit | undefined;
    if (opts.json !== undefined) {
      headers["content-type"] = "application/json";
      body = JSON.stringify(opts.json);
    } else if (opts.form !== undefined) {
      body = opts.form;
    }
    const response = await fetch(url, {
      method,
      headers,
      body,
      redirect: this.followRedirects ? "follow" : "manual",
      signal: AbortSignal.timeout(this.timeout * 1000),
    });
    const text = await response.text();
    const record: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      record[key.toLowerCase()] = value;
    });
    return {
      status: response.status,
      headers: record,
      text,
      json: () => JSON.parse(text),
    };
  }

  get(path: string, opts?: ProbeHttpRequest): Promise<ProbeHttpResponse> {
    return this.request("GET", path, opts);
  }

  post(path: string, opts?: ProbeHttpRequest): Promise<ProbeHttpResponse> {
    return this.request("POST", path, opts);
  }

  close(): void {}
}

export class LiteLLMProbeTransport implements ProbeTransport {
  private readonly key: string;
  private readonly masterKey: string;
  private readonly timeout: number;
  private readonly spendWait: number;
  private readonly clientFactory: NonNullable<LiteLLMProbeTransportOptions["clientFactory"]>;
  private readonly direct: DirectProbeEdit | null;
  private readonly paramsFor: ((model: string) => Record<string, unknown> | null) | null;
  private priceCache: { at: number | null; data: Record<string, Record<string, unknown>> } = {
    at: null,
    data: {},
  };

  constructor(
    private readonly baseUrl: string,
    probeKey: string,
    opts: LiteLLMProbeTransportOptions = {},
  ) {
    this.key = probeKey;
    this.masterKey = opts.masterKey ?? "";
    this.timeout = opts.timeout ?? 90;
    this.spendWait = opts.spendWait ?? 4.0;
    this.clientFactory =
      opts.clientFactory ??
      ((factory) => new FetchProbeClient(factory.baseUrl, factory.timeout, factory.followRedirects));
    this.direct = opts.direct ?? null;
    this.paramsFor = opts.paramsFor ?? null;
  }

  get editCost(): number | null {
    return this.direct?.editCost ?? null;
  }

  private client(): ProbeHttpClient {
    return this.clientFactory({
      baseUrl: this.baseUrl,
      timeout: this.timeout,
      followRedirects: false,
    });
  }

  private async spend(client: ProbeHttpClient): Promise<number | null> {
    try {
      const response = await client.get("/key/info", {
        params: { key: this.key },
        headers: { Authorization: `Bearer ${this.masterKey || this.key}` },
      });
      if (response.status !== 200) return null;
      const body = response.json();
      if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
      const info = (body as Record<string, unknown>).info;
      if (typeof info !== "object" || info === null || Array.isArray(info)) return 0;
      const spend = (info as Record<string, unknown>).spend;
      return typeof spend === "number" && Number.isFinite(spend) ? spend : 0;
    } catch {
      return null;
    }
  }

  private async prices(
    client: ProbeHttpClient,
    model: string,
  ): Promise<Record<string, unknown>> {
    const now = Date.now() / 1000;
    if (this.priceCache.at === null || now - this.priceCache.at >= 300) {
      try {
        const response = await client.get("/model/info", {
          headers: { Authorization: `Bearer ${this.masterKey || this.key}` },
        });
        if (response.status === 200) {
          this.priceCache = {
            at: now,
            data: parseModelInfo(response.json()) as Record<string, Record<string, unknown>>,
          };
        }
      } catch {
        // Keep the previous data (Python PriceBook).
      }
    }
    const info = this.priceCache.data[model];
    return info === undefined ? {} : (normalizePrices(info) as unknown as Record<string, unknown>);
  }

  private async directEdit(model: string, params: ProbeParams): Promise<ProbeOutcome> {
    const started = Date.now();
    const lookup = (this.paramsFor ? this.paramsFor(model) : null) ?? {};
    if (this.direct === null || !this.direct.enabled_for(lookup)) {
      return {
        ok: false,
        errorClass: INCONCLUSIVE,
        latencyMs: 0,
        costUsd: 0,
        images: [],
        costSource: null,
      };
    }
    const dataUrl = `data:image/png;base64,${Buffer.from(params.images![0]!).toString("base64")}`;
    let response: { status: number; headers: Record<string, string>; json(): Promise<unknown> };
    try {
      response = await this.direct.post(lookup, params.prompt, params.size, dataUrl);
    } catch {
      return {
        ok: false,
        errorClass: TRANSIENT,
        latencyMs: Date.now() - started,
        costUsd: 0,
        images: [],
        costSource: null,
      };
    }
    const latency = Date.now() - started;
    if (response.status !== 200) {
      let parsed: unknown = {};
      try {
        parsed = await response.json();
      } catch {
        parsed = {};
      }
      const text = (typeof parsed === "string" ? parsed : JSON.stringify(parsed) ?? "").slice(
        0,
        2000,
      );
      return {
        ok: false,
        errorClass: classifyDirectError(response.status, {
          json: () => parsed,
          text,
        }),
        latencyMs: latency,
        costUsd: 0,
        images: [],
        costSource: null,
      };
    }
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      return {
        ok: false,
        errorClass: TRANSIENT,
        latencyMs: latency,
        costUsd: this.editCost ?? 0,
        images: [],
        costSource: null,
      };
    }
    const rows =
      typeof body === "object" && body !== null && !Array.isArray(body)
        ? ((body as Record<string, unknown>).data ?? [])
        : [];
    const { images, errorClass } = decodeRows(rows);
    const cost = Number(
      this.direct
        .settlementCost(body, money(this.editCost ?? 1.0))
        .toString(),
    );
    if (errorClass !== null) {
      return {
        ok: false,
        errorClass,
        latencyMs: latency,
        costUsd: cost,
        images: [],
        costSource: null,
      };
    }
    if (images.length === 0) {
      return {
        ok: false,
        errorClass: TRANSIENT,
        latencyMs: latency,
        costUsd: cost,
        images: [],
        costSource: null,
      };
    }
    return {
      ok: true,
      errorClass: null,
      latencyMs: latency,
      costUsd: cost,
      images,
      costSource: null,
    };
  }

  async call(
    model: string,
    kind: "generate" | "edit",
    params: ProbeParams,
  ): Promise<ProbeOutcome> {
    if (kind === "edit" && params.direct) return this.directEdit(model, params);
    const client = this.client();
    try {
      const headers = { Authorization: `Bearer ${this.key}` };
      const before = await this.spend(client);
      const started = Date.now();
      let response: ProbeHttpResponse;
      try {
        if (kind === "generate") {
          const body: Record<string, unknown> = {
            model,
            prompt: params.prompt,
            size: params.size,
            n: params.n ?? 1,
            response_format: "b64_json",
          };
          if (params.background) body.background = params.background;
          response = await client.post("/v1/images/generations", { headers, json: body });
        } else {
          const form = new FormData();
          form.append("model", model);
          form.append("prompt", params.prompt);
          form.append("size", params.size);
          form.append("n", "1");
          const images = params.images ?? [];
          const field = images.length > 1 ? "image[]" : "image";
          images.forEach((raw, index) => {
            form.append(
              field,
              new Blob([new Uint8Array(raw)], { type: "image/png" }),
              `in${index}.png`,
            );
          });
          if (params.mask) {
            form.append("mask", new Blob([new Uint8Array(params.mask)], { type: "image/png" }), "mask.png");
          }
          response = await client.post("/v1/images/edits", { headers, form });
        }
      } catch {
        return {
          ok: false,
          errorClass: TRANSIENT,
          latencyMs: Date.now() - started,
          costUsd: null,
          images: [],
          costSource: null,
        };
      }
      const latency = Date.now() - started;
      if (response.status !== 200) {
        return {
          ok: false,
          errorClass: classifyError(response.status, response.text.slice(0, 2000)),
          latencyMs: latency,
          costUsd: null,
          images: [],
          costSource: null,
        };
      }
      let body: unknown = null;
      try {
        body = response.json();
      } catch {
        body = null;
      }
      const usage =
        typeof body === "object" && body !== null && !Array.isArray(body)
          ? (body as Record<string, unknown>).usage
          : undefined;
      const determined = await determineCost({
        headers: response.headers,
        usage,
        prices: () => this.prices(client, model),
        spendBefore: before,
        spendRead: () => this.spend(client),
        spendWait: this.spendWait,
        spendPoll: 0.5,
      });
      const cost = determined.cost === null ? null : Number(determined.cost.toString());
      const rows =
        typeof body === "object" && body !== null && !Array.isArray(body)
          ? ((body as Record<string, unknown>).data ?? [])
          : [];
      let decoded: { images: Uint8Array[]; errorClass: string | null };
      try {
        decoded = decodeRows(rows);
      } catch {
        return {
          ok: false,
          errorClass: TRANSIENT,
          latencyMs: latency,
          costUsd: cost,
          images: [],
          costSource: determined.source,
        };
      }
      if (decoded.errorClass !== null || decoded.images.length === 0) {
        return {
          ok: false,
          errorClass: decoded.errorClass ?? TRANSIENT,
          latencyMs: latency,
          costUsd: cost,
          images: [],
          costSource: determined.source,
        };
      }
      return {
        ok: true,
        errorClass: null,
        latencyMs: latency,
        costUsd: cost,
        images: decoded.images,
        costSource: determined.source,
      };
    } finally {
      client.close();
    }
  }
}
