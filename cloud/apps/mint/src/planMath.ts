import { pyNumStr, pyRound6 } from "@ovid/money";

/**
 * Faithful TS port of server/mint/ovid_plans.py — the plan + allowance math
 * shared by mint and the LiteLLM pools hook. ovid_plans.py is the
 * BYTE-LEVEL AUTHORITY: the STAYING Python hook (litellm_hook/ovid_pools.py)
 * reads exactly the Redis db2 values this module's serializers produce, so
 * every field name, number rendering and JSON key set mirrors the Python
 * source line by line.
 *
 * SNAKE_CASE WIRE FIELDS (documented exception to the camelCase wire rule):
 * the structures below — PlanData, Settings, Pools, PoolsOverride — keep
 * Python's field names verbatim because they ARE the JSON the hook reads.
 *
 * Pure functions only: callers fetch the raw Redis/Postgres values and pass
 * them in. Serialization deviations from Python are exactly one, sanctioned
 * by the plan's Global Constraints: compact JSON separators (","/":") where
 * Python json.dumps defaults emit ", "/": " — parse-identical and hook-safe.
 */

export interface PlanData {
  id: string;
  name: string;
  price_usd: number;
  enabled: boolean;
  aliases: string[];
  window_hours: number;
  mult: number;
  slow_mode: boolean;
  auto_oss: boolean;
}

export interface Settings {
  free_daily_usd: number;
  free_monthly_cap_usd: number;
  est_input_tokens: number;
  est_output_tokens: number;
  est_image_tokens: number;
  slow_rpm: number;
  slow_tpm: number;
  slow_parallel: number;
  normal_rpm: number;
  normal_tpm: number;
  normal_parallel: number;
  hard_ceiling_mult: number;
  auto_oss_members: { model: string; weight: number }[];
  plans: PlanData[];
}

export interface Pools {
  plan_id: string;
  window_hours: number;
  all: number;
  slow_mode: boolean;
  auto_oss: boolean;
}

/** Redis user:{uid}:pools shape — null means "unset" (Python override.get(f) is None). */
export type PoolsOverride = {
  mult?: number | null;
  window_hours?: number | null;
  slow_mode?: boolean | null;
  auto_oss?: boolean | null;
};

export const AUTO_MODEL = "auto";

/** The db2 keys the hook reads — byte-identical to ovid_plans' constants. */
export const DB2 = {
  LIMITS_HASH: "config:limits",
  BASE_BUDGET_KEY: "config:base_daily_usd",
  SLOW_HASH: "pools:slow",
  SLOW_PENDING: "pools:slow_pending",
  MODEL_GROUPS_KEY: "config:model_groups",
} as const;

/** The Python user registry set (server/mint/mint.py ALL_UIDS_SET). */
export const OVID_UIDS_SET = "ovid:uids";

export const SEED_AUTO_OSS_MEMBERS: { model: string; weight: number }[] = [
  { model: "glm-5.3-flash", weight: 1 },
  { model: "deepseek-v4.1-flash", weight: 1 },
  { model: "minimax-m3", weight: 1 },
];

const PLAN_ID_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;

/** name -> (type, seed, lo, hi) — the ovid_plans SCALARS table, same order. */
export interface ScalarSpec {
  type: "int" | "float";
  seed: number;
  lo: number;
  hi: number;
}
export const SCALARS: Record<string, ScalarSpec> = {
  free_monthly_cap_usd: { type: "float", seed: 10.0, lo: 0, hi: 100000 },
  est_input_tokens: { type: "int", seed: 2000, lo: 1, hi: 10_000_000 },
  est_output_tokens: { type: "int", seed: 600, lo: 1, hi: 10_000_000 },
  est_image_tokens: { type: "int", seed: 1500, lo: 1, hi: 10_000_000 },
  slow_rpm: { type: "int", seed: 20, lo: 1, hi: 1_000_000 },
  slow_tpm: { type: "int", seed: 200_000, lo: 1, hi: 1_000_000_000 },
  slow_parallel: { type: "int", seed: 2, lo: 1, hi: 10_000 },
  normal_rpm: { type: "int", seed: 240, lo: 1, hi: 1_000_000 },
  normal_tpm: { type: "int", seed: 4_000_000, lo: 1, hi: 1_000_000_000 },
  normal_parallel: { type: "int", seed: 16, lo: 1, hi: 10_000 },
  hard_ceiling_mult: { type: "float", seed: 3.0, lo: 1, hi: 1000 }, // key ceiling for slow-mode plans
};

/** field -> (lo, hi, default) — the ovid_plans PLAN_NUMBERS table. */
const PLAN_NUMBERS: Record<"price_usd" | "window_hours" | "mult", [number, number, number]> = {
  price_usd: [0, 100000, 0],
  window_hours: [1, 24 * 366, 24],
  mult: [0, 100000, 1],
};

const OVERRIDE_FIELDS = ["mult", "window_hours", "slow_mode", "auto_oss"] as const;

/** Python int(float): truncation toward zero. */
function pyInt(v: number): number {
  return Math.trunc(v);
}

/** Python falsiness for the `p.get(x) or default` idioms (None/False/0/""/[]). */
function pyFalsy(v: unknown): boolean {
  return v == null || v === false || v === 0 || v === "";
}

function hasKey(obj: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

/** ovid_plans._num: float(v) with default on unparseable/NaN (never throws). */
function pyNum(v: unknown, dflt: number): number {
  if (v === null || v === undefined) return dflt; // float(None) → TypeError
  if (typeof v === "number") return Number.isNaN(v) ? dflt : v;
  if (typeof v !== "string") return dflt; // float(dict/…) → TypeError
  if (v.trim() === "") return dflt; // float("") → ValueError
  const n = Number(v);
  return Number.isNaN(n) ? dflt : n;
}

/** ovid_plans._bounded: bools/unparseables → "must be a number"; NaN/range → "must be between". */
function pyBounded(name: string, v: unknown, lo: number, hi: number): number {
  if (typeof v === "boolean") throw new Error(`${name} must be a number`);
  let f: number;
  if (typeof v === "number") {
    f = v;
  } else if (typeof v === "string") {
    if (v.trim() === "") throw new Error(`${name} must be a number`);
    f = Number(v);
    if (Number.isNaN(f)) throw new Error(`${name} must be a number`);
  } else {
    throw new Error(`${name} must be a number`);
  }
  if (Number.isNaN(f) || !(lo <= f && f <= hi)) {
    throw new Error(`${name} must be between ${lo} and ${hi}`);
  }
  return f;
}

// ---------------------------------------------------------------------------
// pyJsonStringify — Python json.dumps parity for the JSON fields in db2.
// JS numbers carry no int/float tag, so int-typed keys are declared by the
// caller (plans: window_hours; every other number in the plans/members JSON
// is a validated Python float). Python renders ints bare ("24") and floats
// via str() ("1.0") — pyNumStr provides the float half.
// ---------------------------------------------------------------------------

const PLAN_INT_KEYS: ReadonlySet<string> = new Set(["window_hours"]);

export function pyJsonStringify(
  value: unknown,
  opts: { intKeys?: ReadonlySet<string>; sortKeys?: boolean } = {},
): string {
  return stringify(value);

  function stringify(v: unknown, key?: string): string {
    if (v === null) return "null";
    if (typeof v === "boolean") return v ? "true" : "false";
    if (typeof v === "number") {
      if (key !== undefined && opts.intKeys?.has(key)) return String(v);
      return pyNumStr(v);
    }
    if (typeof v === "string") return JSON.stringify(v);
    if (Array.isArray(v)) return `[${v.map((e) => stringify(e)).join(",")}]`;
    if (typeof v === "object") {
      const keys = Object.keys(v as Record<string, unknown>);
      if (opts.sortKeys) keys.sort();
      return `{${keys.map((k) => `${JSON.stringify(k)}:${stringify((v as Record<string, unknown>)[k], k)}`).join(",")}}`;
    }
    return "null"; // undefined inside a structure — Python would not have it
  }
}

// ---------------------------------------------------------------------------
// seeds, parse, serialize, validate
// ---------------------------------------------------------------------------

/**
 * First-run plans. The multipliers are the product spec's Auto Mode ratios
 * (§4): Free 1x, Go 1.5x, Plus 5x, Pro 20x. The `aliases` are the stored
 * tier values billing has always written (3x/7x/15x) and must NOT be renamed
 * — they are what `users.tier` already holds for existing subscribers.
 */
export function seedPlans(paidWindowHours: number = 24): PlanData[] {
  return [
    { id: "free", name: "Free", price_usd: 0, enabled: true, aliases: [], window_hours: 24, mult: 1, slow_mode: false, auto_oss: false },
    { id: "starter", name: "Go", price_usd: 5, enabled: true, aliases: ["3x"], window_hours: paidWindowHours, mult: 1.5, slow_mode: false, auto_oss: false },
    { id: "pro", name: "Plus", price_usd: 18, enabled: true, aliases: ["7x"], window_hours: paidWindowHours, mult: 5, slow_mode: false, auto_oss: true },
    { id: "max", name: "Pro", price_usd: 99, enabled: true, aliases: ["15x"], window_hours: paidWindowHours, mult: 20, slow_mode: false, auto_oss: true },
  ];
}

/**
 * Settings from the raw `config:limits` hash + `config:base_daily_usd`;
 * unset values fall back to the seeds. Unknown stored fields are ignored.
 * Invalid stored plans → seedPlans; invalid stored members → [] (plain auto).
 */
export function parseSettings(
  hash: Record<string, string> | null | undefined,
  baseRaw: string | null | undefined,
  seeds?: Partial<Settings>,
): Settings {
  const h = hash ?? {};
  const sd = seeds ?? {};
  const scalars: Record<string, number> = {};
  for (const [name, spec] of Object.entries(SCALARS)) {
    const seed = (sd as Record<string, unknown>)[name];
    const v = pyNum(h[name], seed === undefined ? spec.seed : (seed as number));
    scalars[name] = spec.type === "int" ? pyInt(v) : v;
  }
  let autoOssMembers: { model: string; weight: number }[];
  const rawMembers = h.auto_oss_members;
  if (rawMembers === undefined || rawMembers === null) {
    // unset → the seed members (validated, as Python's single call site does)
    autoOssMembers = validateMembers(sd.auto_oss_members ?? SEED_AUTO_OSS_MEMBERS);
  } else {
    try {
      autoOssMembers = validateMembers(JSON.parse(rawMembers));
    } catch {
      autoOssMembers = []; // stored but invalid → plain auto
    }
  }
  // ovid_plans._json: None/"" → default; unparseable → default
  const defaultPlans = sd.plans && sd.plans.length > 0 ? sd.plans : seedPlans();
  let rawPlans: unknown = defaultPlans;
  if (h.plans !== undefined && h.plans !== null && h.plans !== "") {
    try {
      rawPlans = JSON.parse(h.plans);
    } catch {
      rawPlans = defaultPlans;
    }
  }
  let plans: PlanData[];
  try {
    if (!Array.isArray(rawPlans)) throw new Error("not a list");
    plans = rawPlans.map((p) => validatePlan(p));
  } catch {
    plans = seedPlans();
  }
  return {
    free_daily_usd: pyNum(baseRaw, sd.free_daily_usd ?? 0.15),
    ...scalars,
    auto_oss_members: autoOssMembers,
    plans,
  } as Settings;
}

/**
 * (base_daily value, hash fields) for storage — byte-parity with
 * ovid_plans.serialize_settings: `str(s[k])` per SCALAR typing (ints WITHOUT
 * ".0", floats via pyNumStr WITH it), plans via pyJsonStringify with keys
 * sorted like json.dumps(sort_keys=True), auto_oss_members preserving the
 * Python {model, weight} insertion order (Python dumps them unsorted).
 */
export function serializeSettings(s: Settings): { baseDaily: string; fields: Record<string, string> } {
  const fields: Record<string, string> = {};
  for (const [name, spec] of Object.entries(SCALARS)) {
    const v = s[name as keyof Settings] as number;
    fields[name] = spec.type === "int" ? String(v) : pyNumStr(v);
  }
  fields.plans = pyJsonStringify(s.plans, { intKeys: PLAN_INT_KEYS, sortKeys: true });
  fields.auto_oss_members = pyJsonStringify(s.auto_oss_members);
  return { baseDaily: pyNumStr(s.free_daily_usd), fields };
}

/** ovid_plans.validate_plan. */
export function validatePlan(p: unknown): PlanData {
  if (typeof p !== "object" || p === null || Array.isArray(p)) {
    throw new Error("plan must be an object");
  }
  const rec = p as Record<string, unknown>;
  const pid = pyFalsy(rec.id) ? "" : String(rec.id);
  if (!PLAN_ID_RE.test(pid)) {
    throw new Error("plan id must be 1-32 chars of a-z 0-9 _ -");
  }
  const rawAliases = pyFalsy(rec.aliases) ? [] : rec.aliases;
  if (
    !Array.isArray(rawAliases) ||
    !rawAliases.every((a) => typeof a === "string" && PLAN_ID_RE.test(a))
  ) {
    throw new Error(`plan ${pid}: aliases must be a list of ids`);
  }
  const name = (pyFalsy(rec.name) ? pid : String(rec.name)).slice(0, 64);
  const enabled = hasKey(rec, "enabled") ? Boolean(rec.enabled) : true;
  const slowMode = hasKey(rec, "slow_mode") ? Boolean(rec.slow_mode) : false;
  const autoOss = hasKey(rec, "auto_oss") ? Boolean(rec.auto_oss) : false;
  const priceUsd = pyBounded(`${pid}.price_usd`, hasKey(rec, "price_usd") ? rec.price_usd : PLAN_NUMBERS.price_usd[2], PLAN_NUMBERS.price_usd[0], PLAN_NUMBERS.price_usd[1]);
  const windowHours = pyBounded(`${pid}.window_hours`, hasKey(rec, "window_hours") ? rec.window_hours : PLAN_NUMBERS.window_hours[2], PLAN_NUMBERS.window_hours[0], PLAN_NUMBERS.window_hours[1]);
  const mult = pyBounded(`${pid}.mult`, hasKey(rec, "mult") ? rec.mult : PLAN_NUMBERS.mult[2], PLAN_NUMBERS.mult[0], PLAN_NUMBERS.mult[1]);
  return {
    id: pid,
    name,
    enabled,
    aliases: rawAliases as string[],
    price_usd: priceUsd,
    window_hours: pyInt(windowHours),
    mult,
    slow_mode: slowMode,
    auto_oss: autoOss,
  };
}

/** ovid_plans.validate_members: model names, or {model, weight} objects. */
export function validateMembers(m: unknown): { model: string; weight: number }[] {
  if (!Array.isArray(m)) {
    throw new Error("auto_oss_members must be a list");
  }
  const out: { model: string; weight: number }[] = [];
  const seen = new Set<string>();
  for (const entry of m) {
    let rec: Record<string, unknown>;
    if (typeof entry === "string") {
      rec = { model: entry, weight: 1 };
    } else if (typeof entry === "object" && entry !== null && !Array.isArray(entry)) {
      rec = entry as Record<string, unknown>;
    } else {
      throw new Error("each auto_oss_members entry needs a model name");
    }
    if (typeof rec.model !== "string" || rec.model.trim() === "") {
      throw new Error("each auto_oss_members entry needs a model name");
    }
    const name = rec.model.trim();
    if (name === AUTO_MODEL) {
      throw new Error("auto_oss_members cannot contain 'auto'");
    }
    if (seen.has(name)) {
      throw new Error(`duplicate auto_oss_members entry '${name}'`);
    }
    seen.add(name);
    const weight = pyBounded(`${name}.weight`, hasKey(rec, "weight") ? rec.weight : 1, 0.0001, 1e6);
    out.push({ model: name, weight });
  }
  return out;
}

/** ovid_plans.validate_settings: bounds per SCALARS/PLAN_NUMBERS; 'free' required and enabled; unique ids+aliases. */
export function validateSettings(s: Settings): Settings {
  const scalars: Record<string, number> = {};
  for (const [name, spec] of Object.entries(SCALARS)) {
    const v = pyBounded(name, (s as unknown as Record<string, unknown>)[name], spec.lo, spec.hi);
    scalars[name] = spec.type === "int" ? pyInt(v) : v;
  }
  const members = s.auto_oss_members === undefined ? [] : validateMembers(s.auto_oss_members);
  const plans = (s.plans || []).map((p) => validatePlan(p));
  const ids = plans.map((p) => p.id);
  if (!ids.includes("free")) {
    throw new Error("the 'free' plan is required");
  }
  const names = [...ids, ...plans.flatMap((p) => p.aliases)];
  if (new Set(names).size !== names.length) {
    throw new Error("plan ids and aliases must be unique");
  }
  if (!plans.find((p) => p.id === "free")!.enabled) {
    throw new Error("the 'free' plan must stay enabled");
  }
  return {
    free_daily_usd: pyBounded("free_daily_usd", s.free_daily_usd, 0, 100000),
    ...scalars,
    auto_oss_members: members,
    plans,
  } as Settings;
}

// ---------------------------------------------------------------------------
// plan math
// ---------------------------------------------------------------------------

/**
 * Plan for a stored tier value (id or alias, e.g. legacy 3x/7x/15x). Unknown
 * values are the free plan. Disabled plans keep applying to users already on
 * them (disable = stop selling).
 */
export function findPlan(s: Settings, tier: string | null | undefined): PlanData {
  const t = (tier ?? "").trim();
  let free: PlanData | null = null;
  for (const p of s.plans) {
    if (p.id === "free") free = p;
    if (t && (t === p.id || p.aliases.includes(t))) return p;
  }
  return free ?? seedPlans()[0];
}

/** Value written to user:{uid}:tier. The first alias keeps billing (which knows 3x/7x/15x) compatible. */
export function storedTier(p: PlanData): string {
  return p.aliases.length > 0 ? p.aliases[0] : p.id;
}

export function windowStr(hours: number): string {
  const h = pyInt(hours);
  return h % 24 === 0 && h >= 48 ? `${h / 24}d` : `${h}h`;
}

/** The user's allowance (USD per window). `override` holds the admin's per-user custom plan fields. */
export function userPools(
  s: Settings,
  plan: PlanData,
  freeDaily: number,
  override?: PoolsOverride | null,
): Pools {
  void s; // Python's user_pools(s, plan, …) takes s and never reads it — signature parity
  const p: Record<string, unknown> = { ...plan };
  for (const f of OVERRIDE_FIELDS) {
    const v = override ? (override as Record<string, unknown>)[f] : undefined;
    if (v !== null && v !== undefined) p[f] = v; // Python: override.get(f) is not None
  }
  const hours = pyInt((p.window_hours as number) || 24);
  const total = Number(freeDaily) * Number(p.mult ?? 1) * hours / 24;
  return {
    plan_id: plan.id,
    window_hours: hours,
    all: pyRound6(total), // Python round(total, 6)
    slow_mode: Boolean(p.slow_mode),
    auto_oss: Boolean(p.auto_oss),
  };
}

/**
 * LiteLLM key max_budget per window (a backstop; the hook enforces the
 * allowance per user). Slow-mode plans keep running past the allowance, so
 * their ceiling is hard_ceiling_mult × allowance.
 */
export function keyBudget(pools: Pools, s: Settings): number {
  if (pools.slow_mode) {
    return pyRound6(pools.all * s.hard_ceiling_mult);
  }
  return pools.all;
}

/** Remaining USD. `capLeft` lets the caller apply an extra ceiling (the free monthly backstop). */
export function poolState(
  pools: Pools,
  spent: number,
  capLeft?: number | null,
): { all: { cap: number; spent: number; remaining: number }; slow_mode: boolean } {
  let rem = Math.max(0, pools.all - Number(spent));
  if (capLeft !== null && capLeft !== undefined) {
    rem = Math.min(rem, Math.max(0, capLeft));
  }
  return {
    all: { cap: pools.all, spent: Number(spent), remaining: rem },
    slow_mode: Boolean(pools.slow_mode && rem <= 0),
  };
}

/** Pre-call decision for the hook. */
export function decide(
  pools: Pools,
  spent: number,
): { action: "allow" } | { action: "reject"; code: "daily_limit_reached" } {
  if (pools.all - Number(spent) > 0 || pools.slow_mode) {
    return { action: "allow" };
  }
  return { action: "reject", code: "daily_limit_reached" };
}

/**
 * Weighted-random member + the others (by weight, descending) as fallbacks.
 * Members missing from `known` (LiteLLM model names) are skipped; null means
 * use plain auto. Port of random.choices: r = rng() × total, first bucket
 * with r < cumulative weight (Python's bisect_right bound semantics).
 */
export function pickAutoMember(
  members: { model: string; weight: number }[],
  known: Set<string> | null,
  rng: () => number = Math.random,
): [string, string[]] | null {
  const usable = members.filter((m) => known === null || known.has(m.model));
  if (usable.length === 0) return null;
  const weights = usable.map((m) => m.weight);
  const total = weights.reduce((a, b) => a + b, 0);
  const r = rng() * total;
  let pick = usable[usable.length - 1].model;
  let acc = 0;
  for (let i = 0; i < usable.length; i++) {
    acc += weights[i];
    if (r < acc) {
      pick = usable[i].model;
      break;
    }
  }
  // sorted(usable, key=-weight) — stable, so equal weights keep member order
  const rest = usable
    .slice()
    .sort((a, b) => b.weight - a.weight)
    .filter((m) => m.model !== pick)
    .map((m) => m.model);
  return [pick, rest];
}

export function poolKeys(uid: string): { start: string; spend: string; auto: string } {
  return {
    start: `pool:${uid}:start`,
    spend: `pool:${uid}:spend`,
    auto: `pool:${uid}:auto`, // hash: served model -> requests rewritten from auto
  };
}
