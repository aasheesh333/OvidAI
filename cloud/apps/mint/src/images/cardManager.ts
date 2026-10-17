import { clone, defaultCard, finalize, fingerprint, mergeFacts, assignCostTiers, type Card } from "./capabilities.js";
import type { CardStore } from "./cardStore.js";
import { UNPRICED_WARNING, priceStatus } from "./costing.js";
import { providerModelsEntry, staticExtract } from "./extraction.js";
import { ProbeBusy, type ProbeRunner } from "./probes.js";
import type { ModelCatalogProjection } from "../catalog.js";
import { IMAGE_ALIAS } from "./types.js";

/**
 * Port of server/images/cardmanager.py — card lifecycle: detect new/changed
 * models, extract, probe, publish.
 *
 * Request paths only call `cards()` (memory read). All network work happens in
 * `tick()`, driven by a background loop (`start`) or by tests directly.
 */

const WEEK = 7 * 24 * 3600;

export class Discovered {
  constructor(
    readonly name: string,
    readonly params: Record<string, unknown> = {},
    readonly info: Record<string, unknown> = {},
  ) {}
}

export interface CardManagerOptions {
  /** Background-only JSON fetch (provider models listing). */
  fetchJson?: (url: string) => Promise<unknown>;
  costMap?: Record<string, unknown> | (() => Record<string, unknown> | null);
  ttl?: number;
  clock?: () => number;
  backoffBase?: number;
  backoffMax?: number;
  probeGap?: number;
}

interface ProbeStatus {
  priced: boolean;
  costSource: string | null;
  warnings: string[];
}

export class CardManager {
  readonly store: CardStore;
  readonly runner: ProbeRunner | null;
  private readonly fetchJson: ((url: string) => Promise<unknown>) | null;
  private readonly costMap: CardManagerOptions["costMap"] | null;
  private readonly ttl: number;
  private readonly clock: () => number;
  private readonly backoffBase: number;
  private readonly backoffMax: number;
  private readonly probeGap: number;

  private known = new Map<string, Discovered>();
  private warned = new Set<string>();
  private forced = new Set<string>();
  private lastProbe: number | null = null;
  private cache = new Map<string, Card>();
  private stopped = false;
  private looping = false;
  private wakeResolve: (() => void) | null = null;
  private timer: NodeJS.Timeout | null = null;
  version = 0;

  constructor(store: CardStore, runner: ProbeRunner | null = null, opts: CardManagerOptions = {}) {
    this.store = store;
    this.runner = runner;
    this.fetchJson = opts.fetchJson ?? null;
    this.costMap = opts.costMap ?? null;
    this.ttl = opts.ttl ?? WEEK;
    this.clock = opts.clock ?? (() => Date.now() / 1000);
    this.backoffBase = opts.backoffBase ?? 300;
    this.backoffMax = opts.backoffMax ?? 6 * 3600;
    this.probeGap = opts.probeGap ?? 0;
  }

  /** Load the persisted cards once; callers may seed `observe` afterwards. */
  async load(): Promise<void> {
    for (const card of await this.store.all()) this.cache.set(card.model, card);
  }

  // -- request path (fast, no I/O) ------------------------------------
  observe(discovered: Discovered[]): void {
    this.known = new Map(discovered.map((item) => [item.name, item]));
    for (const item of discovered) this.warnUnpriced(item.name);
  }

  private status(name: string, card: Card | undefined): ProbeStatus {
    const item = this.known.get(name);
    return priceStatus(item ? item.info : {}, Boolean(card?.cost_header_seen));
  }

  private warnUnpriced(name: string): void {
    const { priced } = this.status(name, this.cache.get(name));
    if (priced) {
      this.warned.delete(name);
      return;
    }
    if (this.warned.has(name)) return;
    this.warned.add(name);
    console.warn(
      `[mint] unpriced image model ${JSON.stringify(name)} discovered: ${UNPRICED_WARNING} ` +
        "(user traffic is skipped until priced)",
    );
  }

  card(name: string, params?: Record<string, unknown> | null): Card {
    const values =
      params !== undefined && params !== null
        ? params
        : this.known.get(name)?.params ?? {};
    const fp = fingerprint(name, values);
    const stored = this.cache.get(name);
    const card =
      stored !== undefined && stored.fingerprint === fp ? stored : defaultCard(name, fp);
    // Price state is live (LiteLLM owns prices): evaluated on every read.
    const { priced, costSource, warnings } = this.status(name, card);
    return {
      ...card,
      priced,
      cost_source: costSource,
      warnings: [...(card.probe_warnings ?? []), ...warnings],
    };
  }

  cards(names?: string[]): Card[] {
    const selected = names !== undefined ? [...names] : [...this.known.keys()];
    const cards = selected.map((name) => clone(this.card(name)));
    assignCostTiers(cards);
    for (const card of cards) finalize(card);
    return cards;
  }

  /** The discovered params for a model (probe direct-edit transport). */
  paramsFor(name: string): Record<string, unknown> | null {
    return this.known.get(name)?.params ?? null;
  }

  /** Live private names for the /usage + /v1/models projection (L5). */
  privateModelNames(): string[] {
    const names = new Set<string>();
    for (const name of this.known.keys()) {
      names.add(name);
      names.add(`openai/${name}`);
      const slash = name.indexOf("/");
      names.add(slash === -1 ? name : name.slice(slash + 1));
    }
    return [...names];
  }

  // -- background -------------------------------------------------------
  reprobe(name: string): boolean {
    if (!this.known.has(name)) return false;
    this.forced.add(name);
    return true;
  }

  async due(): Promise<string | null> {
    const now = this.clock();
    for (const [name, item] of this.known) {
      const fp = fingerprint(name, item.params);
      const stored = this.cache.get(name);
      if (this.forced.has(name) || stored === undefined || stored.fingerprint !== fp) {
        return name;
      }
      if (this.runner === null) continue;
      const state = await this.store.probeState(name);
      if (now < state.nextAttemptAt) continue;
      if (stored.state !== "probed" || (stored.probed_at ?? 0) + this.ttl <= now) {
        return name;
      }
    }
    return null;
  }

  /** One unit of background work. Returns the model refreshed, or null. */
  async tick(discover?: () => Promise<Discovered[]> | Discovered[]): Promise<string | null> {
    if (discover !== undefined) {
      try {
        this.observe(await discover());
      } catch (error) {
        console.warn(`[mint] image discovery failed: ${errorName(error)}`);
      }
    }
    const name = await this.due();
    if (name === null) return null;
    const forced = this.forced.has(name);
    if (
      !forced &&
      this.runner !== null &&
      this.probeGap > 0 &&
      this.lastProbe !== null &&
      this.clock() - this.lastProbe < this.probeGap
    ) {
      return null; // stagger: one probe run per probe_gap seconds
    }
    try {
      await this.refresh(name);
    } catch (error) {
      if (error instanceof ProbeBusy) return null;
      throw error;
    }
    return name;
  }

  async refresh(name: string): Promise<Card> {
    const item = this.known.get(name);
    if (item === undefined) throw new Error(`unknown model ${name}`);
    this.forced.delete(name);
    const fp = fingerprint(name, item.params);
    const card = defaultCard(name, fp);
    card.state = "inferred";
    card.edit_transport =
      item.params.edit_transport === "direct" || item.params.edit_transport === "none"
        ? item.params.edit_transport
        : null;
    const previous = this.cache.get(name);
    if (previous && previous.fingerprint === fp && previous.cost_header_seen) {
      card.cost_header_seen = true;
    }
    this.warnUnpriced(name);
    const costMap = await this.costMapValue();
    const providerEntry = await this.providerEntry(item);
    const { facts, meta } = staticExtract(name, item.params, item.info, costMap, providerEntry);
    mergeFacts(card, facts);
    card.static = meta as unknown as Record<string, unknown>;
    finalize(card);
    await this.save(card); // static card is published before any probe spend
    if (this.runner === null) return card;
    const { card: probed, ...summary } = await this.runner.run(card, facts);
    this.lastProbe = this.clock();
    this.warnUnpriced(name);
    probed.static = meta as unknown as Record<string, unknown>;
    await this.save(probed);
    const state = await this.store.probeState(name);
    if (summary.incomplete) {
      const attempts = state.attempts + 1;
      const delay = Math.min(this.backoffMax, this.backoffBase * 2 ** (attempts - 1));
      await this.store.setProbeState(
        name,
        attempts,
        this.clock() + delay,
        summary.stop ?? "transient",
      );
    } else {
      await this.store.setProbeState(name, 0, this.clock() + this.ttl, null);
    }
    return probed;
  }

  private async save(card: Card): Promise<void> {
    await this.store.put(card);
    this.cache.set(card.model, card);
    this.version += 1;
  }

  private async costMapValue(): Promise<Record<string, unknown> | null> {
    try {
      if (typeof this.costMap === "function") return this.costMap();
      return this.costMap ?? null;
    } catch {
      return null;
    }
  }

  private async providerEntry(item: Discovered): Promise<Record<string, unknown> | null> {
    const base =
      typeof item.params.api_base === "string"
        ? item.params.api_base.replace(/\/+$/, "")
        : "";
    if (base === "" || this.fetchJson === null) return null;
    try {
      const listing = await this.fetchJson(`${base}/models`);
      const model =
        typeof item.params.model === "string" && item.params.model !== ""
          ? item.params.model
          : item.name;
      const entry = providerModelsEntry(listing, model);
      return Object.keys(entry).length > 0 ? entry : null;
    } catch {
      return null;
    }
  }

  // -- thread -----------------------------------------------------------
  start(discover: () => Promise<Discovered[]> | Discovered[], intervalS = 60): void {
    if (this.looping) return;
    this.stopped = false;
    const loop = async (): Promise<void> => {
      this.looping = true;
      try {
        // Populate discovery before the first interval; probes still never
        // run on a request path.
        try {
          await this.tick(discover);
        } catch (error) {
          console.warn(`[mint] image card worker: ${errorName(error)}`);
        }
        while (!this.stopped) {
          await this.wait(intervalS * 1000);
          if (this.stopped) break;
          try {
            await this.tick(discover);
          } catch (error) {
            console.warn(`[mint] image card worker: ${errorName(error)}`);
          }
        }
      } finally {
        this.looping = false;
      }
    };
    void loop();
  }

  private wait(milliseconds: number): Promise<void> {
    return new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        this.timer = null;
        this.wakeResolve = null;
        resolve();
      }, milliseconds);
      timer.unref?.();
      this.timer = timer;
      this.wakeResolve = () => {
        if (this.timer !== null) clearTimeout(this.timer);
        this.timer = null;
        this.wakeResolve = null;
        resolve();
      };
    });
  }

  wake(): void {
    this.wakeResolve?.();
  }

  stop(): void {
    this.stopped = true;
    this.wake();
  }
}

/**
 * L5: a LIVE /usage + /v1/models projection. `PublicCatalog` snapshots its
 * private-name set at construction; the CardManager's discovery changes over
 * time, so the projection resolves the set on every call.
 */
export function createLiveCatalogProjection(
  manager: CardManager,
  available: () => boolean,
): ModelCatalogProjection {
  const usage = (rows: { model: string }[]): { model: string }[] => {
    const privateNames = new Set(manager.privateModelNames());
    const result = rows
      .filter(
        (row) =>
          row.model !== "" && !privateNames.has(row.model) && row.model !== IMAGE_ALIAS,
      )
      .map((row) => ({ ...row }));
    if (available()) result.push({ model: IMAGE_ALIAS });
    return result;
  };
  return {
    usage,
    models(rows) {
      return {
        object: "list",
        data: usage(rows).map((row) => {
          const model: {
            id: string;
            object: "model";
            owned_by: "ovid";
            output_modality?: "image";
          } = { id: row.model, object: "model", owned_by: "ovid" };
          if (row.model === IMAGE_ALIAS) model.output_modality = "image";
          return model;
        }),
      };
    },
  };
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : String(error);
}
