import { Decimal } from "decimal.js";
import { money, positiveCost, type Money } from "@ovid/money";

/**
 * Provider-agnostic upstream cost determination — port of
 * server/images/costing.py (pure, no I/O of its own).
 *
 * Priority (first positive, finite, bounded value wins):
 *   1. x-litellm-response-cost header
 *   2. reply usage tokens x LiteLLM model_info prices, else n x per-image
 *   3. bounded key-spend delta
 *   4. null — never fabricate.
 */

export const COST_HEADER = "x-litellm-response-cost";
export const MAX_TOKENS = 10_000_000;

export const UNPRICED_WARNING =
  "unpriced: set the model's price in LiteLLM " +
  "(input/output cost per token, or output cost per image)";

export const PRICE_FIELDS = [
  "input_cost_per_token",
  "output_cost_per_token",
  "input_cost_per_image",
  "output_cost_per_image",
] as const;

export type PriceField = (typeof PRICE_FIELDS)[number];
export type Prices = Partial<Record<PriceField, Money>>;

export type CostSource = "header" | "tokens" | "per_image" | "spend_delta";

/**
 * Python's default Decimal context (28 significant digits, ROUND_HALF_EVEN).
 * costing.py performs token/spend arithmetic without a localcontext, so the
 * ambient default precision is part of the reference behavior.
 */
function pyContext(): Decimal.Constructor {
  return Decimal.clone({ precision: 28, rounding: Decimal.ROUND_HALF_EVEN });
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * costing.py _dec(): untrusted scalar -> finite non-negative Money, else null.
 * Rejects bool/null/arrays/objects; strings are whitespace-stripped; JS
 * numbers go through money()'s exact String(value) pin.
 */
function dec(value: unknown): Money | null {
  if (typeof value === "boolean" || value === null || value === undefined) return null;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return null;
    try {
      return money(value);
    } catch {
      return null;
    }
  }
  if (typeof value === "string") {
    try {
      return money(value.trim());
    } catch {
      return null;
    }
  }
  if (value instanceof Decimal) {
    try {
      return money(value);
    } catch {
      return null;
    }
  }
  return null;
}

/** costing.py header_cost(): exact lower-case key, any read failure -> null. */
export function headerCost(
  headers: Record<string, string> | null | undefined,
  bound?: Money | null,
): Money | null {
  if (headers === null || headers === undefined) return null;
  try {
    return positiveCost(headers[COST_HEADER], bound);
  } catch {
    return null;
  }
}

/**
 * costing.py normalize_prices(): usable positive price fields, each <= 1.
 * Anything unparseable/zero/negative/over-one is dropped.
 */
export function normalizePrices(info: unknown): Prices {
  const out: Prices = {};
  if (!isPlainObject(info)) return out;
  for (const name of PRICE_FIELDS) {
    const value = dec(info[name]);
    if (value !== null && value.greaterThan(0) && value.lessThanOrEqualTo(1)) {
      out[name] = value;
    }
  }
  return out;
}

export function priceStatus(
  info: unknown,
  headerSeen = false,
): { priced: boolean; costSource: "tokens" | "per_image" | "header" | null; warnings: string[] } {
  const prices = normalizePrices(info);
  if ("input_cost_per_token" in prices || "output_cost_per_token" in prices) {
    return { priced: true, costSource: "tokens", warnings: [] };
  }
  if ("input_cost_per_image" in prices || "output_cost_per_image" in prices) {
    return { priced: true, costSource: "per_image", warnings: [] };
  }
  if (headerSeen) return { priced: true, costSource: "header", warnings: [] };
  return { priced: false, costSource: null, warnings: [UNPRICED_WARNING] };
}

/** costing.py _tokens(): first plausible count (0..10M, non-bool), truncated. */
function tokens(usage: Record<string, unknown>, ...names: string[]): number | null {
  for (const name of names) {
    const raw = usage[name];
    if (typeof raw === "boolean" || typeof raw !== "number") continue;
    if (!Number.isFinite(raw)) continue;
    if (raw >= 0 && raw <= MAX_TOKENS) return Math.trunc(raw);
  }
  return null;
}

/**
 * costing.py token_cost(): token formula when the reply has counts, otherwise
 * the per-image formula. `prices` must be normalized (Money values).
 */
export function tokenCost(
  usage: unknown,
  prices: Prices | null | undefined,
  n = 1,
  bound?: Money | null,
): Money | null {
  if (!prices || Object.keys(prices).length === 0) return null;
  const u = isPlainObject(usage) ? usage : {};
  const tin = tokens(u, "input_tokens", "prompt_tokens");
  const tout = tokens(u, "output_tokens", "completion_tokens");
  const Ctx = pyContext();
  const zero = new Ctx(0);
  let total: Decimal;
  if (tin || tout) {
    total = new Ctx(tin ?? 0)
      .times(prices.input_cost_per_token ?? zero)
      .plus(new Ctx(tout ?? 0).times(prices.output_cost_per_token ?? zero));
  } else {
    const count =
      typeof n === "number" && Number.isInteger(n) && n > 0 && n <= 64 ? n : 1;
    total = new Ctx(count).times(
      (prices.input_cost_per_image ?? zero).plus(prices.output_cost_per_image ?? zero),
    );
  }
  return positiveCost(total, bound);
}

/** costing.py spend_delta_cost(): positive finite delta only. */
export function spendDeltaCost(
  before: number | null | undefined,
  after: number | null | undefined,
  bound?: Money | null,
): Money | null {
  if (before === null || before === undefined || after === null || after === undefined) {
    return null;
  }
  if (
    typeof before !== "number" ||
    typeof after !== "number" ||
    !Number.isFinite(before) ||
    !Number.isFinite(after) ||
    after <= before
  ) {
    return null;
  }
  try {
    const Ctx = pyContext();
    const delta = new Ctx(String(after)).minus(new Ctx(String(before)));
    return positiveCost(delta, bound);
  } catch {
    return null;
  }
}

export interface DetermineCostOptions {
  headers?: Record<string, string> | null;
  usage?: unknown;
  prices?: unknown | (() => unknown);
  n?: number;
  spendBefore?: number | null;
  spendRead?: (() => Promise<number | null>) | null;
  spendWait?: number;
  spendPoll?: number;
  sleep?: (seconds: number) => Promise<void>;
  bound?: Money | null;
}

/**
 * costing.py determine_cost(): header -> tokens -> bounded spend-delta poll ->
 * (null, null). `prices` may be a normalized dict or a callable.
 */
export async function determineCost(
  opts: DetermineCostOptions = {},
): Promise<{ cost: Money | null; source: CostSource | null }> {
  const cost = headerCost(opts.headers, opts.bound);
  if (cost !== null) return { cost, source: "header" };

  let prices: unknown = opts.prices;
  if (typeof prices === "function") {
    try {
      prices = await (prices as () => unknown)();
    } catch {
      prices = null;
    }
  }
  const token = tokenCost(
    opts.usage,
    isPlainObject(prices) ? (prices as Prices) : null,
    opts.n ?? 1,
    opts.bound,
  );
  if (token !== null) return { cost: token, source: "tokens" };

  if (opts.spendBefore !== null && opts.spendBefore !== undefined && opts.spendRead) {
    const spendWait = opts.spendWait ?? 0;
    const spendPoll = opts.spendPoll ?? 0.5;
    const sleep =
      opts.sleep ??
      ((seconds: number) => new Promise<void>((resolve) => setTimeout(resolve, seconds * 1000)));
    let waited = 0;
    for (;;) {
      const delta = spendDeltaCost(opts.spendBefore, await opts.spendRead(), opts.bound);
      if (delta !== null) return { cost: delta, source: "spend_delta" };
      if (waited >= spendWait) return { cost: null, source: null };
      const step = Math.min(Math.max(spendPoll, 0.01), spendWait - waited);
      await sleep(step);
      waited += step;
    }
  }
  return { cost: null, source: null };
}

/** costing.py parse_model_info(): first deployment with a usable price wins. */
export function parseModelInfo(payload: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const rows = isPlainObject(payload) && Array.isArray(payload.data) ? payload.data : [];
  for (const row of rows) {
    if (!isPlainObject(row) || typeof row.model_name !== "string") continue;
    const name = row.model_name;
    const info = row.model_info;
    const priced = Object.keys(normalizePrices(info)).length > 0;
    const existingPriced = name in out && Object.keys(normalizePrices(out[name])).length > 0;
    if (!(name in out) || (priced && !existingPriced)) out[name] = info;
  }
  return out;
}

export interface PriceBookOptions {
  ttl?: number;
  missInterval?: number;
  clock?: () => number;
  /** Python's default is true; tests pin false for deterministic refreshes. */
  background?: boolean;
}

/**
 * costing.py PriceBook: in-memory TTL cache with rate-limited cold misses and
 * stale-while-revalidate. Fetch errors keep the previous data.
 */
export class PriceBook {
  private data: Record<string, Prices> = {};
  private at: number | null = null;
  private tried: number | null = null;
  private refreshing = false;
  private readonly ttl: number;
  private readonly missInterval: number;
  private readonly clock: () => number;
  private readonly background: boolean;

  constructor(
    private readonly fetchPrices: () => Promise<Record<string, unknown>>,
    opts: PriceBookOptions = {},
  ) {
    this.ttl = opts.ttl ?? 300;
    this.missInterval = opts.missInterval ?? 30;
    this.clock = opts.clock ?? (() => Date.now() / 1000);
    this.background = opts.background ?? true;
  }

  private async refreshNow(): Promise<void> {
    this.tried = this.clock();
    let fresh: unknown;
    try {
      fresh = await this.fetchPrices();
    } catch {
      return; // errors keep the previous data
    }
    if (isPlainObject(fresh)) {
      const data: Record<string, Prices> = {};
      for (const [model, info] of Object.entries(fresh)) {
        data[model] = normalizePrices(info);
      }
      this.data = data;
      this.at = this.clock();
    }
  }

  /** Force a re-read now (admin POST /images/admin/refresh-prices). */
  async refresh(): Promise<void> {
    await this.refreshNow();
  }

  async get(model: string): Promise<Prices | undefined> {
    const now = this.clock();
    const stale = this.at === null || now - this.at >= this.ttl;
    const have = this.data[model];
    // Python truthiness: an EMPTY normalized price map is "no data" and goes
    // through the rate-limited miss path instead of being served as a hit.
    const hasHave = have !== undefined && Object.keys(have).length > 0;

    if (hasHave && !stale) return have;
    if (hasHave && stale) {
      if (this.background && !this.refreshing) {
        this.refreshing = true;
        void this.refreshNow().finally(() => {
          this.refreshing = false;
        });
      } else if (!this.background) {
        await this.refreshNow();
      }
      // Python `self._data.get(model) or have`: an empty refresh keeps the
      // previous (non-empty) data.
      const refreshed = this.data[model];
      return refreshed !== undefined && Object.keys(refreshed).length > 0
        ? refreshed
        : have;
    }

    if (this.tried === null || now - this.tried >= this.missInterval) {
      await this.refreshNow();
    }
    return this.data[model];
  }
}
