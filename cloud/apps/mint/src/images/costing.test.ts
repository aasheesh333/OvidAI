import { describe, expect, it } from "vitest";
import { Decimal } from "decimal.js";
import { discounted, money } from "@ovid/money";
import {
  COST_HEADER,
  PriceBook,
  UNPRICED_WARNING,
  determineCost,
  headerCost,
  normalizePrices,
  parseModelInfo,
  priceStatus,
  spendDeltaCost,
  tokenCost,
} from "./costing.js";

/**
 * Port of server/images/tests/test_costing.py. Every vector is transcribed
 * from the Python reference; Money values are compared by VALUE
 * (`.equals`) because decimal.js normalizes trailing zeros while Python
 * Decimal preserves them (Task 1's documented, value-safe divergence).
 */

const P25 = {
  input_cost_per_token: money("9e-08"),
  output_cost_per_token: money("9e-06"),
};

const USAGE25 = {
  total_tokens: 1296,
  input_tokens: 6,
  output_tokens: 1290,
  input_tokens_details: {},
  output_tokens_details: null,
};

function eqMoney(actual: Decimal | null, expected: string): void {
  expect(actual).not.toBeNull();
  expect(actual!.equals(new Decimal(expected))).toBe(true);
}

describe("costing (port of costing.py)", () => {
  it("header wins over tokens and spend", async () => {
    const { cost, source } = await determineCost({
      headers: { [COST_HEADER]: "0.0017928" },
      usage: USAGE25,
      prices: P25,
    });
    expect(source).toBe("header");
    eqMoney(cost, "0.0017928");
  });

  it("bad header falls through to tokens", async () => {
    for (const bad of ["nan", "inf", "-1", "0", "abc", "", "1e999", "5000"]) {
      const { source } = await determineCost({
        headers: { [COST_HEADER]: bad },
        usage: USAGE25,
        prices: P25,
      });
      expect(source, bad).toBe("tokens");
    }
  });

  it("tokens: gemini 2.5 vector", async () => {
    const { cost, source } = await determineCost({
      headers: {},
      usage: USAGE25,
      prices: () => P25,
    });
    expect(source).toBe("tokens");
    eqMoney(cost, "0.01161054");
    expect(Math.abs(cost!.toNumber() - 0.0116)).toBeLessThan(1e-4);
  });

  it("usage naming variants (prompt/completion aliases)", () => {
    const alt = { prompt_tokens: 6, completion_tokens: 1290 };
    const a = tokenCost(alt, P25)!;
    const b = tokenCost(USAGE25, P25)!;
    expect(a.equals(b)).toBe(true);
  });

  it("per-image fallback only when there are no token counts", () => {
    const prices = normalizePrices({
      input_cost_per_image: 0.01,
      output_cost_per_image: 0.03,
    });
    eqMoney(tokenCost(null, prices, 2), "0.08");
    eqMoney(tokenCost({ input_tokens: 0, output_tokens: 0 }, prices), "0.04");
  });

  it("tokens preferred over per-image prices", () => {
    const prices = { ...P25, input_cost_per_image: money("0.5") };
    const a = tokenCost(USAGE25, prices)!;
    const b = tokenCost(USAGE25, P25)!;
    expect(a.equals(b)).toBe(true);
  });

  it("missing prices fall to spend delta", async () => {
    const { cost, source } = await determineCost({
      headers: {},
      usage: USAGE25,
      prices: {},
      spendBefore: 1.0,
      spendRead: async () => 1.25,
    });
    expect(source).toBe("spend_delta");
    eqMoney(cost, "0.25");
  });

  it("spend lag: one delayed re-read", async () => {
    const reads = [1.0, 1.5];
    const sleeps: number[] = [];
    const { cost, source } = await determineCost({
      spendBefore: 1.0,
      spendRead: async () => reads.shift()!,
      spendWait: 1.5,
      spendPoll: 1.5,
      sleep: async (s) => {
        sleeps.push(s);
      },
    });
    expect(source).toBe("spend_delta");
    eqMoney(cost, "0.5");
    expect(sleeps).toEqual([1.5]);
  });

  it("spend retry is bounded by spendWait", async () => {
    let n = 0;
    const sleeps: number[] = [];
    const { cost, source } = await determineCost({
      spendBefore: 1.0,
      spendRead: async () => {
        n += 1;
        return 1.0;
      },
      spendWait: 1.5,
      spendPoll: 1.5,
      sleep: async (s) => {
        sleeps.push(s);
      },
    });
    expect(cost).toBeNull();
    expect(source).toBeNull();
    expect(n).toBe(2);
    expect(sleeps).toEqual([1.5]);
  });

  it("nothing usable is null (never fabricated)", async () => {
    expect(
      await determineCost({ headers: {}, usage: {}, prices: P25, spendBefore: null }),
    ).toEqual({ cost: null, source: null });
    expect(await determineCost()).toEqual({ cost: null, source: null });
  });

  it("rejects garbage at every source", () => {
    for (const bad of [
      0,
      -1,
      Number.NaN,
      Number.POSITIVE_INFINITY,
      true,
      null,
      [],
      10 ** 9,
      "1e500",
      new Decimal("NaN"),
    ]) {
      expect(headerCost({ [COST_HEADER]: bad as unknown as string }), String(bad)).toBeNull();
    }
    for (const usage of [
      { input_tokens: -5, output_tokens: -5 },
      { output_tokens: Number.NaN },
      { output_tokens: 10 ** 12 },
      { output_tokens: true },
    ]) {
      expect(tokenCost(usage, P25), JSON.stringify(usage)).toBeNull();
    }
    expect(
      normalizePrices({
        input_cost_per_token: -1,
        output_cost_per_token: "x",
        input_cost_per_image: 99,
      }),
    ).toEqual({});
    expect(spendDeltaCost(1.0, Number.POSITIVE_INFINITY)).toBeNull();
    expect(spendDeltaCost(2.0, 1.0)).toBeNull();
    expect(spendDeltaCost(null, 1.0)).toBeNull();
  });

  it("caps every source at the bound", async () => {
    const bound = money("1.00");
    const header = await determineCost({ headers: { [COST_HEADER]: "5" }, bound });
    eqMoney(header.cost, "1");
    eqMoney(tokenCost({ output_tokens: 10_000_000 }, P25, 1, bound), "1");
    eqMoney(spendDeltaCost(0.0, 7.0, bound), "1");
  });

  it("decimal precision matches the ledger discount", () => {
    const cost = tokenCost(USAGE25, P25)!;
    expect(cost.equals(new Decimal("0.01161054"))).toBe(true);
    const expected = new Decimal("0.01161054").times("0.30");
    expect(discounted(cost).equals(expected)).toBe(true);
  });

  it("token counts are truncated to ints and finite-bounded like Python", () => {
    const truncated = tokenCost({ input_tokens: 6.9, output_tokens: 1290 }, P25)!;
    expect(truncated.equals(tokenCost(USAGE25, P25)!)).toBe(true);
    expect(tokenCost({ output_tokens: Number.POSITIVE_INFINITY }, P25)).toBeNull();
    expect(tokenCost({ output_tokens: -0.5 }, P25)).toBeNull();
  });

  it("price book: TTL cache, rate-limited misses, forced stale refresh", async () => {
    let t = 0;
    const calls: number[] = [];
    const fetch = async () => {
      calls.push(1);
      return { m: { output_cost_per_token: 1e-6 }, u: {} };
    };
    const book = new PriceBook(fetch, {
      ttl: 300,
      missInterval: 30,
      clock: () => t,
      background: false,
    });

    const m = await book.get("m");
    expect(m!.output_cost_per_token!.equals(money("1e-6"))).toBe(true);
    await book.get("m");
    expect(calls.length).toBe(1);

    expect(await book.get("unknown")).toBeUndefined(); // rate-limited miss
    expect(calls.length).toBe(1);

    t = 31;
    // An EMPTY normalized price map is not a cache hit (Python truthiness):
    // it goes through the rate-limited miss path.
    expect(await book.get("u")).toEqual({});
    expect(calls.length).toBe(2);
    expect(await book.get("unknown")).toBeUndefined();
    expect(calls.length).toBe(2);

    t = 400;
    await book.get("m");
    expect(calls.length).toBe(3);
  });

  it("price book: fetch errors keep previous data and cold errors return undefined", async () => {
    let boom = false;
    let t = 0;
    const book = new PriceBook(
      async () => {
        if (boom) throw new Error("x");
        return { m: { output_cost_per_token: 1e-6 } };
      },
      { ttl: 300, missInterval: 30, clock: () => t, background: false },
    );
    const first = await book.get("m");
    expect(first).toBeDefined();
    boom = true;
    t = 400;
    const stale = await book.get("m");
    expect(stale!.output_cost_per_token!.equals(money("1e-6"))).toBe(true);

    const dead = new PriceBook(
      async () => {
        throw new Error("x");
      },
      { background: false },
    );
    expect(await dead.get("m")).toBeUndefined();
  });

  it("refresh() forces a re-read", async () => {
    let calls = 0;
    const book = new PriceBook(
      async () => {
        calls += 1;
        return {};
      },
      { background: false },
    );
    await book.get("m");
    await book.refresh();
    expect(calls).toBe(2);
  });

  it("parse model info: first deployment with a price wins", () => {
    const out = parseModelInfo({
      data: [
        { model_name: "a", model_info: {} },
        { model_name: "a", model_info: { output_cost_per_token: 1e-6 } },
        { model_name: 5 },
        "junk",
      ],
    });
    const prices = normalizePrices(out["a"]);
    expect(prices.output_cost_per_token!.equals(money("1e-6"))).toBe(true);
    expect(parseModelInfo(null)).toEqual({});
    expect(parseModelInfo({ data: "nope" })).toEqual({});
  });

  it("price status: LiteLLM-owned prices only, verbatim unpriced warning", () => {
    expect(priceStatus(P25)).toEqual({ priced: true, costSource: "tokens", warnings: [] });
    expect(
      priceStatus({ output_cost_per_image: 0.04 }),
    ).toEqual({ priced: true, costSource: "per_image", warnings: [] });
    expect(priceStatus({}, true)).toEqual({ priced: true, costSource: "header", warnings: [] });
    expect(priceStatus({})).toEqual({
      priced: false,
      costSource: null,
      warnings: [UNPRICED_WARNING],
    });
    expect(UNPRICED_WARNING).toBe(
      "unpriced: set the model's price in LiteLLM " +
        "(input/output cost per token, or output cost per image)",
    );
  });

  it("headerCost ignores missing/garbage header containers", () => {
    expect(headerCost(null)).toBeNull();
    expect(headerCost({})).toBeNull();
    expect(headerCost({ [COST_HEADER]: "0.5" })!.equals(money("0.5"))).toBe(true);
  });
});
