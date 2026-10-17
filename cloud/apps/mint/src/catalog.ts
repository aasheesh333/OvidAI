import type { MintDeps } from "./app.js";
import { IMAGE_ALIAS } from "./images/types.js";
import { AUTO_MODEL, DB2 } from "./planMath.js";

/**
 * Model catalog + hook publication — port of mint.py's model_catalog /
 * catalog_for / _available_models / refresh_model_groups.
 *
 * LiteLLM /model/info deployments are grouped by public model name (the
 * `auto` group has one deployment per member). The catalog carries, per
 * group, every deployment's prices, its LiteLLM modes, the underlying model
 * ids and the LAST deployment's legacy per-token prices (the pre-P9 /usage
 * fields, last-wins).
 *
 * catalogFor also publishes `config:model_groups` (sorted JSON) for the
 * UNMODIFIED Python hook, which only routes auto to members that exist. An
 * empty catalog is never published — a transient LiteLLM outage must not wipe
 * the hook's known-set (mint.py's `if cat["groups"]:` guard).
 */

export interface CatalogGroup {
  id: string;
  name: string;
  inputs: number[];
  outputs: number[];
  per_image: number[];
  modes: Set<string>;
  underlying: string[];
  /** Back-compat /usage prices: the last deployment wins, like Python. */
  legacy: { input_cost_per_token: unknown; output_cost_per_token: unknown };
}

export interface Catalog {
  groups: Record<string, CatalogGroup>;
  /** model_info.id → underlying model (spend-log model_id fallback). */
  dep_underlying: Record<string, string>;
  /** underlying (and its suffix) → public group name. */
  under_to_public: Record<string, string>;
  /** The hidden auto routing group(s). */
  auto_groups: Set<string>;
}

function emptyCatalog(): Catalog {
  return {
    groups: {},
    dep_underlying: {},
    under_to_public: {},
    auto_groups: new Set([AUTO_MODEL]),
  };
}

/** mint.py `_LAST_CATALOG` — availableModels() is synchronous by contract. */
let lastCatalog: Catalog = emptyCatalog();

/** Python `_price`: float(v), null on parse error, and only positive values. */
function price(v: unknown): number | null {
  if (v === null || v === undefined) return null;
  let n: number;
  if (typeof v === "number") {
    n = v;
  } else if (typeof v === "string") {
    if (v.trim() === "") return null;
    n = Number(v);
  } else {
    return null;
  }
  if (Number.isNaN(n)) return null;
  return n > 0 ? n : null;
}

/** Python `model.split("/", 1)[-1]` — the part after the FIRST slash. */
function suffix(model: string): string {
  const i = model.indexOf("/");
  return i === -1 ? model : model.slice(i + 1);
}

/** mint.py `_public_for`: underlying model → public group name. */
export function publicFor(cat: Catalog, under: string): string | null {
  if (!under) return null;
  return cat.under_to_public[under] ?? cat.under_to_public[suffix(under)] ?? null;
}

/** mint.py `_group_kind`: image when a deployment is an image mode or priced per image only. */
export function groupKind(g: CatalogGroup | undefined): "chat" | "image" {
  if (g === undefined) return "chat";
  const imageMode = g.modes.has("image_generation") || g.modes.has("image_edit");
  if (imageMode || (g.per_image.length > 0 && g.inputs.length === 0)) return "image";
  return "chat";
}

/**
 * LiteLLM /model/info → the grouped catalog. Fail-soft: the admin wrapper
 * already maps a non-200/network error to [], so an outage returns an empty
 * catalog and never throws.
 */
export async function catalogFor(deps: MintDeps): Promise<Catalog> {
  const rows = await deps.litellm.modelInfo();
  const groups: Record<string, CatalogGroup> = {};
  const depUnderlying: Record<string, string> = {};
  const underToPublic: Record<string, string> = {};

  for (const m of rows) {
    const name = m.model_name ?? "";
    if (!name) continue;
    const info = m.model_info ?? {};
    const params = m.litellm_params ?? {};
    const under = String(params.model ?? "");
    let g = groups[name];
    if (g === undefined) {
      g = {
        id: name,
        name,
        inputs: [],
        outputs: [],
        per_image: [],
        modes: new Set<string>(),
        underlying: [],
        legacy: { input_cost_per_token: null, output_cost_per_token: null },
      };
      groups[name] = g;
    }
    const disp = info.display_name ?? info.ovid_display_name;
    if (disp) g.name = String(disp);
    const priced: [unknown, number[]][] = [
      [info.input_cost_per_token, g.inputs],
      [info.output_cost_per_token, g.outputs],
      [info.output_cost_per_image, g.per_image],
    ];
    for (const [raw, bucket] of priced) {
      const p = price(raw);
      if (p !== null) bucket.push(p);
    }
    if (info.mode) g.modes.add(String(info.mode));
    if (under) g.underlying.push(under);
    // Back-compat: the old /usage de-duped by name, last deployment wins.
    g.legacy = {
      input_cost_per_token: info.input_cost_per_token ?? null,
      output_cost_per_token: info.output_cost_per_token ?? null,
    };
    if (info.id) depUnderlying[String(info.id)] = under;
    if (under && name !== AUTO_MODEL) {
      if (underToPublic[under] === undefined) underToPublic[under] = name;
      const sfx = suffix(under);
      if (underToPublic[sfx] === undefined) underToPublic[sfx] = name;
    }
  }

  const cat: Catalog = {
    groups,
    dep_underlying: depUnderlying,
    under_to_public: underToPublic,
    auto_groups: new Set([AUTO_MODEL]),
  };

  if (Object.keys(groups).length > 0) {
    lastCatalog = cat;
    // Compact JSON (the plan's sanctioned deviation from Python's ", "/": ").
    const blob = JSON.stringify(Object.keys(groups).sort());
    if ((await deps.redis.get(DB2.MODEL_GROUPS_KEY)) !== blob) {
      await deps.redis.set(DB2.MODEL_GROUPS_KEY, blob);
    }
  }
  return cat;
}

/** The sweeper's catalog refresh (mint.py refresh_model_groups). */
export async function refreshModelGroups(deps: MintDeps): Promise<void> {
  await catalogFor(deps);
}

/**
 * Model rows the app may see (mint.py _available_models). Task 13 wraps this
 * to drop private image backends and add the public image alias.
 */
export function availableModels(deps: MintDeps): { model: string }[] {
  void deps;
  return projectAvailableModels(
    Object.keys(lastCatalog.groups).map((name) => ({ model: name })),
  );
}

// ── Task 13: PublicCatalog masking hook ─────────────────────────────────────
// The images mount installs the projection on the public app's onReady. Until
// then (e.g. an isolated Task-6 /v1/models test) the passthrough is unchanged.

export interface ModelCatalogProjection {
  usage(rows: { model: string }[]): { model: string }[];
  models(rows: { model: string }[]): {
    object: "list";
    data: { id: string; object: "model"; owned_by: "ovid"; output_modality?: "image" }[];
  };
}

let modelCatalogProjection: ModelCatalogProjection | null = null;

export function setModelCatalogProjection(projection: ModelCatalogProjection | null): void {
  modelCatalogProjection = projection;
}

/** Test seam: drop the images mount's projection. */
export function resetModelCatalogProjectionForTests(): void {
  modelCatalogProjection = null;
}

/** /usage rows: hide private image backends, add the alias while mounted. */
export function projectAvailableModels(rows: { model: string }[]): { model: string }[] {
  return modelCatalogProjection === null ? rows : modelCatalogProjection.usage(rows);
}

/**
 * /v1/models body. The images capability is deliberately not advertised to a
 * text-key request: the public catalog removes the alias (its separate
 * authenticated capability endpoint advertises it).
 */
export function projectModelCatalog(rows: { model: string }[]): {
  object: "list";
  data: { id: string; object: "model"; owned_by: "ovid"; output_modality?: "image" }[];
} {
  if (modelCatalogProjection === null) {
    return {
      object: "list",
      data: rows.map((row) => ({ id: row.model, object: "model", owned_by: "ovid" })),
    };
  }
  const catalog = modelCatalogProjection.models(rows);
  return { object: "list", data: catalog.data.filter((row) => row.id !== IMAGE_ALIAS) };
}

/** Test seam: the catalog cache is process-wide like Python's _LAST_CATALOG. */
export function resetCatalogCacheForTests(): void {
  lastCatalog = emptyCatalog();
}
