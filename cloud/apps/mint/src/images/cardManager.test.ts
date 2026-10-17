import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import Fastify from "fastify";
import type { Db } from "@ovid/db";
import { exactSum, money, type Money } from "@ovid/money";
import { UNPRICED_WARNING } from "./costing.js";
import { defaultCard, fingerprint, supports, type Card } from "./capabilities.js";
import { createCardStore, type CardStore } from "./cardStore.js";
import { CardManager, Discovered, createLiveCatalogProjection } from "./cardManager.js";
import { ProbeRunner, UNSUPPORTED, type ProbeOutcome, type ProbeTransport } from "./probes.js";
import { registerImagesAdminRoutes } from "./adminRoutes.js";
import type { MintEnv } from "../env.js";
import { TEST_DATABASE_URL, closeDb, resetTestDb } from "../test/env.js";

/** Programmable in-process transport (Python test_probes.FakeLiteLLM shape). */
class FakeTransport implements ProbeTransport {
  readonly calls: { model: string; label: string; size: unknown }[] = [];
  transient = new Set<string>();

  constructor(
    private readonly opts: {
      sizes?: string[];
      edit?: boolean;
      mask?: boolean;
      multi?: boolean;
      transparent?: boolean;
      n2?: boolean;
      cost?: number;
      latency?: number;
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
      latency: 1500,
      ...opts,
    };
  }

  private label(kind: "generate" | "edit", p: Record<string, unknown>): string {
    if (kind === "generate") {
      if (p.background) return "transparent";
      if (p.n === 2) return "variations";
      return "generate";
    }
    if (p.mask) return "inpaint";
    return ((p.images as unknown[]).length > 1 ? "multi_image" : "edit") as string;
  }

  async call(
    model: string,
    kind: "generate" | "edit",
    p: Record<string, unknown>,
  ): Promise<ProbeOutcome> {
    const label = this.label(kind, p);
    this.calls.push({ model, label, size: p.size });
    if (this.transient.has(label)) {
      return { ok: false, errorClass: "transient", latencyMs: 100, costUsd: 0, images: [], costSource: null };
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
      return { ok: false, errorClass: UNSUPPORTED, latencyMs: 50, costUsd: 0, images: [], costSource: null };
    }
    return {
      ok: true,
      errorClass: null,
      latencyMs: this.opts.latency!,
      costUsd: this.opts.cost!,
      images: [new Uint8Array([0x89, 0x50, 0x4e, 0x47])],
      costSource: null,
    };
  }
}

const enabled = TEST_DATABASE_URL !== undefined;
const describeDb = enabled ? describe : describe.skip;

describeDb("CardManager + Postgres CardStore (cardmanager.py / cardstore.py)", () => {
  let db: Db;
  let now: number;
  let store: CardStore;
  let fake: FakeTransport;
  let runner: ProbeRunner;
  let manager: CardManager;

  const params = { model: "openai/m", api_base: "https://a/v1" };
  const discover = (value: Record<string, unknown> = params) => () => [
    new Discovered("cb/m", value, { mode: "image_generation" }),
  ];

  beforeAll(async () => {
    db = await resetTestDb();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  beforeEach(async () => {
    await db.$client.unsafe(
      "TRUNCATE image_cards, image_card_history, image_probe_log, image_probe_state",
    );
    now = 1_000_000;
    store = createCardStore(db, () => now);
    fake = new FakeTransport();
    runner = new ProbeRunner(fake, store, { clock: () => now });
    manager = new CardManager(store, runner, { clock: () => now, ttl: 7 * 86400 });
  });

  it("serves a default card until the background tick, then a probed one", async () => {
    manager.observe(discover()());
    expect(manager.card("cb/m").state).toBe("default");
    expect(supports(manager.card("cb/m"), "edit")).toBe(false);
    expect(fake.calls).toHaveLength(0); // the request path never probes

    expect(await manager.tick(discover())).toBe("cb/m");
    const card = manager.card("cb/m");
    expect(card.state).toBe("probed");
    expect(supports(card, "edit")).toBe(true);
    expect(await manager.tick(discover())).toBeNull();
  });

  it("stores the static card before spending on probes", async () => {
    const states: string[] = [];
    const original = fake.call.bind(fake);
    fake.call = async (model, kind, p) => {
      states.push((await store.get("cb/m"))!.state);
      return original(model, kind, p);
    };
    await manager.tick(discover());
    expect(states[0]).toBe("inferred");
  });

  it("re-extracts on a fingerprint change and keeps history", async () => {
    await manager.tick(discover());
    const calls = fake.calls.length;
    const changed = { model: "openai/m", api_base: "https://other/v1" };
    expect(manager.card("cb/m", changed).state).toBe("default");
    expect(await manager.tick(discover(changed))).toBe("cb/m");
    expect(fake.calls.length).toBeGreaterThan(calls);
    expect(manager.card("cb/m", changed).fingerprint).toBe(fingerprint("cb/m", changed));
    expect((await store.history("cb/m")).length).toBeGreaterThanOrEqual(4);
  });

  it("re-probes weekly and on an admin force", async () => {
    await manager.tick(discover());
    now += 6 * 86400;
    expect(await manager.tick(discover())).toBeNull();
    now += 2 * 86400;
    expect(await manager.tick(discover())).toBe("cb/m");
    expect(await manager.tick(discover())).toBeNull();
    expect(manager.reprobe("cb/m")).toBe(true);
    expect(await manager.tick(discover())).toBe("cb/m");
    expect(manager.reprobe("nope")).toBe(false);
  });

  it("backs off exponentially after a transient failure", async () => {
    fake.transient = new Set(["generate"]);
    await manager.tick(discover());
    const state = await store.probeState("cb/m");
    expect(state.attempts).toBe(1);
    expect(await manager.tick(discover())).toBeNull(); // inside backoff
    now += 301;
    expect(await manager.tick(discover())).toBe("cb/m");
    expect((await store.probeState("cb/m")).attempts).toBe(2);
    expect((await store.probeState("cb/m")).nextAttemptAt).toBeGreaterThanOrEqual(now + 600);
  });

  it("cards survive a restart (same store, no runner)", async () => {
    await manager.tick(discover());
    const again = new CardManager(store, null, { clock: () => now });
    await again.load();
    again.observe(discover()());
    expect(again.card("cb/m").state).toBe("probed");
  });

  it("without a probe key only the static card is published", async () => {
    const staticOnly = new CardManager(store, null, { clock: () => now });
    expect(await staticOnly.tick(discover())).toBe("cb/m");
    expect(await staticOnly.tick(discover())).toBeNull();
    expect(staticOnly.card("cb/m").state).toBe("inferred");
    expect(fake.calls).toHaveLength(0);
  });

  it("uses provider metadata when the base URL exposes it", async () => {
    const withProvider = new CardManager(store, null, {
      clock: () => now,
      fetchJson: async () => ({
        data: [
          {
            id: "m",
            architecture: {
              input_modalities: ["text", "image"],
              output_modalities: ["image"],
            },
          },
        ],
      }),
    });
    await withProvider.tick(discover());
    expect(supports(withProvider.card("cb/m"), "edit")).toBe(true);
    expect(withProvider.card("cb/m").static.sources).toContain("provider.architecture");
  });

  it("M3: copies edit_transport from discovered params so DirectEdit is reachable", async () => {
    const direct = { ...params, edit_transport: "direct" };
    await manager.tick(discover(direct));
    const card = manager.card("cb/m");
    expect(card.edit_transport).toBe("direct");
    expect(supports(card, "edit")).toBe(true);
    expect((await store.get("cb/m"))!.edit_transport).toBe("direct");
  });

  it("tracks priced state live and warns once per unpriced model", async () => {
    const staticOnly = new CardManager(store, null, { clock: () => now });
    staticOnly.observe([new Discovered("u/m", { model: "m" }, { mode: "image_generation" })]);
    await staticOnly.tick(() => [
      new Discovered("u/m", { model: "m" }, { mode: "image_generation" }),
    ]);
    let card = staticOnly.cards()[0]!;
    expect(card.priced).toBe(false);
    expect(card.warnings).toEqual([UNPRICED_WARNING]);

    staticOnly.observe([
      new Discovered(
        "u/m",
        { model: "m" },
        { mode: "image_generation", input_cost_per_token: 1e-6 },
      ),
    ]);
    card = staticOnly.cards()[0]!;
    expect(card.priced).toBe(true);
    expect(card.cost_source).toBe("tokens");
    expect(card.warnings).toEqual([]);
  });

  it("stores exact probe spend (never a SQL float SUM)", async () => {
    await store.logProbe("m", "generate:1024x1024", true, null, 10, money("0.1"));
    await store.logProbe("m", "edit", true, null, 10, money("0.2"));
    expect((await store.spentSince(0)).equals(exactSum([money("0.1"), money("0.2")]))).toBe(true);
    await store.logProbe("m", "generate:1536x1024", true, null, 10, money("0.05"));
    expect((await store.spentSince(0)).toString()).toBe("0.35");
  });

  it("upserts and reads probe state", async () => {
    expect(await store.probeState("m")).toEqual({ attempts: 0, nextAttemptAt: 0, lastError: null });
    await store.setProbeState("m", 2, 1234, "transient");
    expect(await store.probeState("m")).toEqual({
      attempts: 2,
      nextAttemptAt: 1234,
      lastError: "transient",
    });
  });

  it("L5: the catalog projection is live, not a boot snapshot", () => {
    const projection = createLiveCatalogProjection(manager, () => true);
    manager.observe([new Discovered("cb/one", { model: "m" }, {})]);
    expect(projection.usage([{ model: "cb/one" }, { model: "chat" }])).toEqual([
      { model: "chat" },
      { model: "ovid-image" },
    ]);
    // A model discovered later is masked without reinstalling the projection.
    manager.observe([
      new Discovered("cb/one", { model: "m" }, {}),
      new Discovered("cb/two", { model: "m" }, {}),
    ]);
    expect(projection.usage([{ model: "cb/one" }, { model: "cb/two" }, { model: "chat" }])).toEqual([
      { model: "chat" },
      { model: "ovid-image" },
    ]);
    expect(manager.privateModelNames()).toContain("cb/two");
  });
});

describeDb("images admin routes (admin.py)", () => {
  let db: Db;
  let store: CardStore;
  let manager: CardManager;
  let app: ReturnType<typeof Fastify>;

  const auth = { authorization: "Bearer master" };

  beforeAll(async () => {
    db = await resetTestDb();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  beforeEach(async () => {
    await db.$client.unsafe(
      "TRUNCATE image_cards, image_card_history, image_probe_log, image_probe_state",
    );
    const now = 1_000_000;
    store = createCardStore(db, () => now);
    manager = new CardManager(store, null, { clock: () => now });
    manager.observe([
      new Discovered("cb/m", { model: "m", api_base: "https://a/v1" }, { mode: "image_generation" }),
    ]);
    await manager.tick(() => [
      new Discovered("cb/m", { model: "m", api_base: "https://a/v1" }, { mode: "image_generation" }),
    ]);
    app = Fastify();
    registerImagesAdminRoutes(app, { env: { adminMasterKey: "master" } as MintEnv }, manager, {
      wake: () => undefined,
      refreshPrices: async () => undefined,
    });
    await app.ready();
  });

  it("rejects a missing or wrong master key with the exact forbidden body", async () => {
    for (const headers of [{}, { authorization: "Bearer nope" }]) {
      const response = await app.inject({ method: "GET", url: "/images/admin/cards", headers });
      expect(response.statusCode).toBe(403);
      expect(response.json()).toEqual({ error: { code: "forbidden" } });
    }
    const refresh = await app.inject({ method: "POST", url: "/images/admin/refresh-prices" });
    expect(refresh.statusCode).toBe(403);
    const reprobe = await app.inject({
      method: "POST",
      url: "/images/admin/reprobe",
      payload: { model: "cb/m" },
    });
    expect(reprobe.statusCode).toBe(403);
  });

  it("returns cards with history/probe_state and the probe budget, no-store", async () => {
    const response = await app.inject({
      method: "GET",
      url: "/images/admin/cards",
      headers: auth,
    });
    expect(response.statusCode).toBe(200);
    expect(response.headers["cache-control"]).toBe("no-store");
    const body = response.json();
    expect(body.schema).toBe(1);
    expect(body.cards).toHaveLength(1);
    expect(body.cards[0].model).toBe("cb/m");
    expect(body.cards[0].history.length).toBeGreaterThan(0);
    expect(body.cards[0].probe_state).toEqual({
      attempts: 0,
      nextAttemptAt: 0,
      lastError: null,
    });
    expect(body.probe_budget).toEqual({
      probes_enabled: false,
      probe_spend_24h_usd: 0,
      probe_daily_cap_usd: null,
      probe_daily_left_usd: null,
      probe_per_call_cap_usd: null,
    });
  });

  it("refresh-prices returns the live priced map", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/images/admin/refresh-prices",
      headers: auth,
    });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ refreshed: true, priced: { "cb/m": false } });
  });

  it("reprobe accepts a model or slug, rejects unknown, and validates the body", async () => {
    const byModel = await app.inject({
      method: "POST",
      url: "/images/admin/reprobe",
      headers: auth,
      payload: { model: "cb/m" },
    });
    expect(byModel.statusCode).toBe(202);
    expect(byModel.json()).toEqual({ queued: "cb/m" });

    const bySlug = await app.inject({
      method: "POST",
      url: "/images/admin/reprobe",
      headers: auth,
      payload: { model: manager.cards()[0]!.slug },
    });
    expect(bySlug.statusCode).toBe(202);

    const unknown = await app.inject({
      method: "POST",
      url: "/images/admin/reprobe",
      headers: auth,
      payload: { model: "nope" },
    });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json()).toEqual({ error: { code: "unknown_model" } });

    const invalid = await app.inject({
      method: "POST",
      url: "/images/admin/reprobe",
      headers: auth,
      payload: { model: 3 },
    });
    expect(invalid.statusCode).toBe(400);
    expect(invalid.json()).toEqual({ error: { code: "invalid_request" } });
  });
});
