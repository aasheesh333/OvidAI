import { describe, expect, it } from "vitest";
import { Decimal } from "decimal.js";
import { exactSum, money, type Money } from "@ovid/money";
import { defaultCard, supports, type Card } from "./capabilities.js";
import type { CardStore } from "./cardStore.js";
import {
  AUTH,
  BUDGET,
  INCONCLUSIVE,
  ProbeBusy,
  ProbeRunner,
  TRANSIENT,
  UNSUPPORTED,
  URL_RESPONSE,
  WARNINGS,
  classifyDirectError,
  classifyError,
  decodeRows,
  sniffFormat,
  syntheticPng,
  type ProbeHttpClient,
  type ProbeHttpResponse,
  type ProbeOutcome,
  type ProbeTransport,
  LiteLLMProbeTransport,
} from "./probes.js";

function pngBytes(alpha = false): Uint8Array {
  return syntheticPng(8, alpha);
}

function response(
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): ProbeHttpResponse {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  return {
    status,
    headers,
    text,
    json: () => (typeof body === "string" ? JSON.parse(body) : body),
  };
}

interface LoggedProbe {
  model: string;
  probe: string;
  ok: boolean;
  errorClass: string | null;
  latencyMs: number | null;
  costUsd: string;
  at: number;
}

class MemoryStore implements CardStore {
  readonly cards = new Map<string, Card>();
  readonly logs: LoggedProbe[] = [];
  readonly states = new Map<
    string,
    { attempts: number; nextAttemptAt: number; lastError: string | null }
  >();
  constructor(private readonly clock: () => number = () => 1_000_000) {}

  async get(model: string): Promise<Card | null> {
    return this.cards.get(model) ?? null;
  }
  async all(): Promise<Card[]> {
    return [...this.cards.values()];
  }
  async put(card: Card): Promise<void> {
    this.cards.set(card.model, card);
  }
  async history(): Promise<{ fingerprint: string; state: string; at: number }[]> {
    return [];
  }
  async logProbe(
    model: string,
    probe: string,
    ok: boolean,
    errorClass: string | null,
    latencyMs: number | null,
    costUsd: Money,
  ): Promise<void> {
    this.logs.push({
      model,
      probe,
      ok,
      errorClass,
      latencyMs,
      costUsd: costUsd.toString(),
      at: this.clock(),
    });
  }
  async spentSince(epoch: number): Promise<Money> {
    return exactSum(
      this.logs
        .filter((row) => row.at >= epoch)
        .map((row) => money(row.costUsd)),
    );
  }
  async probeState(model: string): Promise<{
    attempts: number;
    nextAttemptAt: number;
    lastError: string | null;
  }> {
    return this.states.get(model) ?? { attempts: 0, nextAttemptAt: 0, lastError: null };
  }
  async setProbeState(
    model: string,
    attempts: number,
    nextAttemptAt: number,
    lastError?: string | null,
  ): Promise<void> {
    this.states.set(model, { attempts, nextAttemptAt, lastError: lastError ?? null });
  }
}

/** Python's FakeLiteLLM: a programmable in-process probe transport. */
class FakeLiteLLM implements ProbeTransport {
  readonly calls: { model: string; label: string; size: string | undefined }[] = [];
  active = 0;
  maxActive = 0;
  private readonly hold: Promise<void> | null;
  private readonly releaseHold: () => void;

  constructor(
    public opts: {
      sizes?: string[];
      edit?: boolean;
      mask?: boolean;
      multi?: boolean;
      transparent?: boolean;
      n2?: boolean;
      cost?: number;
      transient?: string[];
      latency?: number;
      hold?: boolean;
    } = {},
  ) {
    this.opts = {
      sizes: ["1024x1024", "1536x1024"],
      edit: true,
      mask: true,
      multi: true,
      transparent: true,
      n2: true,
      cost: 0.02,
      transient: [],
      latency: 1500,
      hold: false,
      ...opts,
    };
    let resolve!: () => void;
    this.hold = this.opts.hold
      ? new Promise<void>((r) => {
          resolve = r;
        })
      : null;
    this.releaseHold = resolve ?? (() => undefined);
  }

  private label(kind: "generate" | "edit", p: Record<string, unknown>): string {
    if (kind === "generate") {
      if (p.background) return "transparent";
      if (p.n === 2) return "variations";
      return "generate";
    }
    if (p.mask) return "inpaint";
    return ((p.images as Uint8Array[]).length > 1 ? "multi_image" : "edit") as string;
  }

  async call(
    model: string,
    kind: "generate" | "edit",
    p: Record<string, unknown>,
  ): Promise<ProbeOutcome> {
    this.active += 1;
    this.maxActive = Math.max(this.maxActive, this.active);
    try {
      if (this.hold !== null) await this.hold;
      const label = this.label(kind, p);
      this.calls.push({ model, label, size: p.size as string | undefined });
      if (this.opts.transient!.includes(label)) {
        return {
          ok: false,
          errorClass: TRANSIENT,
          latencyMs: 100,
          costUsd: 0,
          images: [],
          costSource: null,
        };
      }
      const ok =
        {
          generate: (this.opts.sizes as string[]).includes(p.size as string),
          edit: this.opts.edit,
          inpaint: this.opts.edit && this.opts.mask,
          multi_image: this.opts.edit && this.opts.multi,
          transparent: true,
          variations: this.opts.n2,
        }[label] ?? false;
      if (!ok) {
        return {
          ok: false,
          errorClass: UNSUPPORTED,
          latencyMs: 50,
          costUsd: 0,
          images: [],
          costSource: null,
        };
      }
      const images =
        label === "variations"
          ? [pngBytes(), pngBytes()]
          : [pngBytes(label === "transparent" && this.opts.transparent === true)];
      return {
        ok: true,
        errorClass: null,
        latencyMs: this.opts.latency!,
        costUsd: this.opts.cost!,
        images,
        costSource: null,
      };
    } finally {
      this.active -= 1;
    }
  }

  unblock(): void {
    this.releaseHold();
  }
}

function runner(transport: ProbeTransport, store: CardStore, opts: Record<string, unknown> = {}) {
  return new ProbeRunner(transport, store, { clock: () => 1_000_000, ...opts });
}

function card(name = "m"): Card {
  return defaultCard(name);
}

describe("probes.py — budget-capped runner", () => {
  it("a fully capable model becomes a probed card", async () => {
    const fake = new FakeLiteLLM();
    const store = new MemoryStore();
    const { card: probed, spent } = await runner(fake, store).run(card());
    expect(probed.state).toBe("probed");
    for (const op of [
      "generate",
      "edit",
      "inpaint",
      "multi_image",
      "transparent_output",
      "variations",
      "outpaint",
    ]) {
      expect(supports(probed, op), op).toBe(true);
    }
    expect(probed.operations.edit?.source).toBe("probed");
    expect(probed.operations.outpaint?.source).toBe("inferred");
    expect(probed.sizes.native).toEqual(["1024x1024", "1536x1024"]);
    expect(probed.sizes.aspect_ratios).toContain("3:2");
    expect(probed.latency_ms_p50).toBe(1500);
    expect(probed.measured_cost_usd).toBe(0.02);
    expect(probed.max_n).toBe(2);
    expect(probed.probed_at).toBeGreaterThan(0);
    expect(spent.toString()).toBe(await store.spentSince(0).then((v) => v.toString()));
  });

  it("unsupported operations are absent and dependents are skipped", async () => {
    const fake = new FakeLiteLLM({ edit: false, transparent: false, n2: false });
    const { card: probed } = await runner(fake, new MemoryStore()).run(card());
    expect(supports(probed, "generate")).toBe(true);
    for (const op of ["edit", "inpaint", "multi_image", "transparent_output", "variations"]) {
      expect(supports(probed, op), op).toBe(false);
    }
    const labels = fake.calls.map((call) => call.label);
    expect(labels).not.toContain("inpaint");
    expect(labels).not.toContain("multi_image");
    expect(probed.state).toBe("probed");
  });

  it("a transient 503 leaves the capability unchanged", async () => {
    const fake = new FakeLiteLLM({ transient: ["edit"] });
    const before = card();
    before.operations.edit = { supported: true, source: "declared", confidence: 0.85 };
    const { card: probed, ...summary } = await runner(fake, new MemoryStore()).run(before);
    expect(supports(probed, "edit")).toBe(true);
    expect(probed.operations.edit?.source).toBe("declared");
    expect(summary.transient).toBe(true);
    expect(summary.incomplete).toBe(true);
    expect(probed.state).toBe("inferred");
    expect(fake.calls.map((call) => call.label)).not.toContain("inpaint");
  });

  it("caps the candidate sizes", async () => {
    const fake = new FakeLiteLLM({ sizes: ["1024x1024"] });
    await runner(fake, new MemoryStore(), { maxSizes: 2 }).run(card());
    expect(new Set(fake.calls.map((call) => call.size))).toEqual(
      new Set(["1024x1024", "1536x1024"]),
    );
  });

  it("skips without spending when the estimate exceeds the per-probe cap", async () => {
    const fake = new FakeLiteLLM();
    const c = card();
    c.measured_cost_usd = 0.9;
    const store = new MemoryStore();
    const { card: probed, ...summary } = await runner(fake, store, {
      perProbeCap: 0.5,
    }).run(c);
    expect(summary.stop).toBe("estimate_exceeds_cap");
    expect(summary.spent.toString()).toBe("0");
    expect(fake.calls).toHaveLength(0);
    expect(probed.probe_warnings).toEqual([WARNINGS.estimate_exceeds_cap]);
    expect(probed.probe_stop).toBe("estimate_exceeds_cap");
  });

  it("stops the run when a probe costs more than the per-probe cap", async () => {
    const fake = new FakeLiteLLM({ cost: 0.9 });
    const { card: probed, ...summary } = await runner(fake, new MemoryStore(), {
      perProbeCap: 0.5,
    }).run(card());
    expect(summary.stop).toBe("per_probe_cap");
    expect(fake.calls).toHaveLength(1);
    expect(probed.state).toBe("inferred");
    expect(probed.probe_warnings).toContain(WARNINGS.per_probe_cap);
  });

  it("enforces the daily budget across runs and rolls over after 24h", async () => {
    let now = 1_000_000;
    const clock = () => now;
    const fake = new FakeLiteLLM({ cost: 0.02 });
    const store = new MemoryStore(clock);
    const probe = new ProbeRunner(fake, store, {
      clock,
      dailyCap: 0.05,
      estimatedCost: 0.02,
    });
    const first = await probe.run(card());
    expect(first.stop).toBe("daily_budget");
    expect(first.card.probe_warnings).toContain(WARNINGS.daily_budget);
    const used = fake.calls.length;
    const second = await probe.run(card());
    expect(second.stop).toBe("daily_budget");
    expect(fake.calls).toHaveLength(used);
    now += 25 * 3600;
    await probe.run(card());
    expect(fake.calls.length).toBeGreaterThan(used);
  });

  it("aborts on a provider budget error", async () => {
    const fake: ProbeTransport = {
      async call() {
        return {
          ok: false,
          errorClass: BUDGET,
          latencyMs: 10,
          costUsd: 0,
          images: [],
          costSource: null,
        };
      },
    };
    const { card: probed, stop } = await runner(fake, new MemoryStore()).run(card());
    expect(stop).toBe(BUDGET);
    expect(probed.state).toBe("inferred");
    expect(probed.probe_warnings).toContain(WARNINGS[BUDGET]);
  });

  it("runs one probe at a time across runners", async () => {
    const fake = new FakeLiteLLM({ hold: true });
    const store = new MemoryStore();
    const first = runner(fake, store).run(card("a"));
    while (fake.active === 0) {
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    await expect(runner(new FakeLiteLLM(), new MemoryStore()).run(card("b"))).rejects.toBeInstanceOf(
      ProbeBusy,
    );
    fake.unblock();
    await first;
    expect(fake.maxActive).toBe(1);
  });

  it("warns on URL replies without adopting any capability", async () => {
    const fake: ProbeTransport = {
      async call(_model, kind, p) {
        if (kind === "generate" && !p.background && p.n !== 2) {
          return {
            ok: false,
            errorClass: URL_RESPONSE,
            latencyMs: 10,
            costUsd: 0,
            images: [],
            costSource: null,
          };
        }
        return {
          ok: true,
          errorClass: null,
          latencyMs: 10,
          costUsd: 0.01,
          images: [pngBytes()],
          costSource: null,
        };
      },
    };
    const { card: probed } = await runner(fake, new MemoryStore()).run(card());
    expect(probed.probe_warnings).toContain(WARNINGS[URL_RESPONSE]);
    expect(probed.state).toBe("inferred");
  });

  it("stops on auth with the verbatim warning", async () => {
    const fake: ProbeTransport = {
      async call() {
        return {
          ok: false,
          errorClass: AUTH,
          latencyMs: 10,
          costUsd: 0,
          images: [],
          costSource: null,
        };
      },
    };
    const { card: probed, stop } = await runner(fake, new MemoryStore()).run(card());
    expect(stop).toBe(AUTH);
    expect(probed.probe_warnings).toContain(WARNINGS[AUTH]);
  });
});

describe("probes.py — classification and decoding", () => {
  it("classifies errors exactly", () => {
    expect(classifyError(400, "size not supported")).toBe(UNSUPPORTED);
    expect(classifyError(422, "")).toBe(UNSUPPORTED);
    expect(classifyError(429, "rate limit")).toBe(TRANSIENT);
    expect(classifyError(503, "no_capacity")).toBe(TRANSIENT);
    expect(classifyError(500, "model does not support edits")).toBe(UNSUPPORTED);
    expect(classifyError(400, "image too small, minimum 256")).toBe(INCONCLUSIVE);
    expect(classifyError(400, "Budget has been exceeded")).toBe(BUDGET);
    expect(classifyError(401, "")).toBe(AUTH);
    expect(classifyError(402, "")).toBe(BUDGET);
    expect(classifyError(400, "content policy violation")).toBe(INCONCLUSIVE);
    expect(classifyError(404, "")).toBe(UNSUPPORTED);
    expect(classifyError(408, "")).toBe(TRANSIENT);
  });

  it("classifies direct structured refusals only on documented codes", () => {
    const body = (value: unknown) =>
      response(400, value) as unknown as { json(): unknown; text: string };
    expect(
      classifyDirectError(400, body({ error: { code: "not_an_image_model" } }) as never),
    ).toBe(UNSUPPORTED);
    expect(
      classifyDirectError(400, body({ error: { code: "unsupported_modality" } }) as never),
    ).toBe(UNSUPPORTED);
    expect(
      classifyDirectError(400, body({ error: { message: "not supported" } }) as never),
    ).toBe(INCONCLUSIVE);
    expect(classifyDirectError(500, body({}) as never)).toBe(TRANSIENT);
  });

  it("decodes only b64 image rows and never accepts URLs", () => {
    const png = Buffer.from(pngBytes()).toString("base64");
    expect(decodeRows([{ b64_json: png }]).errorClass).toBeNull();
    expect(decodeRows([{ url: "https://x/y.png" }]).errorClass).toBe(URL_RESPONSE);
    expect(decodeRows([{}]).errorClass).toBe(TRANSIENT);
    expect(decodeRows([{ b64_json: "not base64!" }]).errorClass).toBe(INCONCLUSIVE);
    expect(decodeRows([{ b64_json: Buffer.from("hello").toString("base64") }]).errorClass).toBe(
      INCONCLUSIVE,
    );
    expect(decodeRows([{ b64_json: "%%%" }]).errorClass).toBe(INCONCLUSIVE);
  });

  it("sniffs PNG/JPEG/WebP magic", () => {
    expect(sniffFormat(pngBytes())).toBe("png");
    expect(sniffFormat(Buffer.from([0xff, 0xd8, 0xff, 0x00]))).toBe("jpeg");
    expect(
      sniffFormat(Buffer.concat([Buffer.from("RIFF"), Buffer.alloc(4), Buffer.from("WEBP")])),
    ).toBe("webp");
    expect(sniffFormat(Buffer.from("hello"))).toBeNull();
  });

  it("synthetic PNGs are valid and carry alpha only when asked", () => {
    const rgb = syntheticPng(8, false);
    const rgba = syntheticPng(8, true);
    expect(sniffFormat(rgb)).toBe("png");
    expect(sniffFormat(rgba)).toBe("png");
    expect(Buffer.from(rgb).includes(Buffer.from("IDAT"))).toBe(true);
    // The alpha variant's left half is transparent, so its IDAT differs.
    expect(Buffer.from(rgba).equals(Buffer.from(rgb))).toBe(false);
  });
});

describe("probes.py — LiteLLM HTTP transport", () => {
  interface Seen {
    method: string;
    path: string;
    headers: Record<string, string>;
    params: Record<string, string>;
    json?: Record<string, unknown>;
    form?: FormData;
  }

  class FakeClient implements ProbeHttpClient {
    constructor(
      private readonly handler: (seen: Seen) => ProbeHttpResponse,
      private readonly seen: Seen[] = [],
    ) {}
    async get(path: string, opts: { headers?: Record<string, string>; params?: Record<string, string> } = {}) {
      const seen: Seen = {
        method: "GET",
        path,
        headers: opts.headers ?? {},
        params: opts.params ?? {},
      };
      this.seen.push(seen);
      return this.handler(seen);
    }
    async post(
      path: string,
      opts: {
        headers?: Record<string, string>;
        json?: Record<string, unknown>;
        form?: FormData;
      } = {},
    ) {
      const seen: Seen = {
        method: "POST",
        path,
        headers: opts.headers ?? {},
        params: {},
        json: opts.json,
        form: opts.form,
      };
      this.seen.push(seen);
      return this.handler(seen);
    }
    close(): void {}
  }

  function transport(
    handler: (seen: Seen) => ProbeHttpResponse,
    seen: Seen[] = [],
  ): LiteLLMProbeTransport {
    return new LiteLLMProbeTransport("http://litellm", "sk-probe", {
      masterKey: "master",
      spendWait: 0,
      clientFactory: () => new FakeClient(handler, seen),
    });
  }

  it("uses the probe key and the cost header", async () => {
    const seen: Seen[] = [];
    const t = transport((request) => {
      if (request.path === "/key/info") return response(200, { info: { spend: 0 } });
      return response(
        200,
        { data: [{ b64_json: Buffer.from(pngBytes()).toString("base64") }] },
        { "x-litellm-response-cost": "0.03" },
      );
    }, seen);
    const out = await t.call("cb/x", "generate", { prompt: "p", size: "1024x1024" });
    expect(out.ok).toBe(true);
    expect(out.costUsd).toBe(0.03);
    const generation = seen.find((row) => row.path === "/v1/images/generations")!;
    expect(generation.headers.Authorization).toBe("Bearer sk-probe");
    expect(generation.json?.response_format).toBe("b64_json");
  });

  it("sends image[] and mask for edits and classifies refusals", async () => {
    const seen: Seen[] = [];
    const t = transport((request) => {
      if (request.path === "/key/info") return response(200, { info: { spend: 0 } });
      return response(400, { error: { message: "mask is not supported" } });
    }, seen);
    const out = await t.call("m", "edit", {
      prompt: "p",
      size: "1024x1024",
      images: [pngBytes(), pngBytes()],
      mask: pngBytes(true),
    });
    expect([out.ok, out.errorClass]).toEqual([false, UNSUPPORTED]);
    const edit = seen.find((row) => row.path === "/v1/images/edits")!;
    expect(edit.form).toBeInstanceOf(FormData);
    expect(edit.form!.getAll("image[]")).toHaveLength(2);
    expect(edit.form!.get("mask")).not.toBeNull();
    expect(edit.form!.get("model")).toBe("m");
  });

  it("treats network errors as transient", async () => {
    const t = transport((request) => {
      if (request.path === "/key/info") return response(200, { info: { spend: 0 } });
      throw new Error("connect timeout");
    });
    expect(
      (await t.call("m", "generate", { prompt: "p", size: "1024x1024" })).errorClass,
    ).toBe(TRANSIENT);
  });

  it("classifies a plain-text direct provider error from the raw body", async () => {
    // A non-JSON provider body must not be reduced to JSON.stringify({}),
    // which would make e.g. "insufficient quota" look transient.
    const direct = {
      enabled_for: () => true,
      post: async () => ({
        status: 429,
        headers: {},
        json: async () => {
          throw new Error("not json");
        },
        text: async () => "insufficient quota for this project",
      }),
      settlementCost: () => money("0.04"),
    };
    const t = new LiteLLMProbeTransport("http://litellm", "sk-probe", {
      masterKey: "master",
      spendWait: 0,
      clientFactory: () => new FakeClient(() => response(500, {})),
      direct,
      paramsFor: () => ({ model: "openai/cb/m", api_base: "https://api.inferhub.dev/v1" }),
    });
    const out = await t.call("cb/m", "edit", {
      prompt: "p",
      size: "1024x1024",
      images: [pngBytes()],
      direct: true,
    });
    expect(out.errorClass).toBe(BUDGET);
  });

  it("falls back to the bounded key-spend delta", async () => {
    const spend = [0];
    const t = transport((request) => {
      if (request.path === "/key/info") return response(200, { info: { spend: spend[0] } });
      if (request.path === "/model/info") return response(200, { data: [] });
      spend[0] = 0.07;
      return response(200, {
        data: [{ b64_json: Buffer.from(pngBytes()).toString("base64") }],
      });
    });
    const out = await t.call("m", "generate", { prompt: "p", size: "1024x1024" });
    expect(out.costUsd).toBeCloseTo(0.07, 10);
  });

  it("measures Gemini-style usage-token cost from model info", async () => {
    const t = transport((request) => {
      if (request.path === "/key/info") return response(200, { info: { spend: 0 } });
      if (request.path === "/model/info") {
        return response(200, {
          data: [
            {
              model_name: "cb/g",
              model_info: {
                input_cost_per_token: 9e-8,
                output_cost_per_token: 9e-6,
              },
            },
          ],
        });
      }
      return response(200, {
        usage: { input_tokens: 6, output_tokens: 1290 },
        data: [{ b64_json: Buffer.from(pngBytes()).toString("base64") }],
      });
    });
    const out = await t.call("cb/g", "generate", { prompt: "p", size: "1024x1024" });
    expect(out.ok).toBe(true);
    expect(out.costUsd).toBeCloseTo(0.01161054, 10);
  });
});

describe("probes.py — money is exact", () => {
  it("sums probe spend without binary float drift", async () => {
    const fake = new FakeLiteLLM({ cost: 0.1 });
    const store = new MemoryStore();
    const { spent } = await runner(fake, store, { dailyCap: 5, perProbeCap: 1 }).run(card());
    expect(spent).toBeInstanceOf(Decimal);
    // Every successful probe costs exactly 0.1; the sum is decimal-exact.
    expect(spent.toString()).toBe("0.8");
    expect((await store.spentSince(0)).equals(spent)).toBe(true);
  });
});
