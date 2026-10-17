import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { pyRound, pyRound6 } from "@ovid/money";
import type { MintDeps } from "./app.js";
import {
  AUTO_MODEL,
  poolKeys,
  poolState,
  storedTier,
  userPools,
  windowStr,
  type Pools,
  type Settings,
} from "./planMath.js";
import {
  availableModels,
  catalogFor,
  groupKind,
  publicFor,
  type Catalog,
  type CatalogGroup,
} from "./catalog.js";
import type { SpendLogRow } from "./litellmAdmin.js";
import type { BillingService } from "./billing/service.js";
import { getOverride, getSettings, userFreeDaily } from "./settings.js";
import {
  currentWindowStart,
  floatOr,
  freeCapUsd,
  hookSpend,
  poolInSlowMode,
  intOr,
  isoUtc,
  monthSpent,
  planFor,
  poolSyncSlowMode,
  poolUserKeyIds,
  windowBounds,
} from "./windows.js";

/**
 * POST /usage — port of mint.py's compute_usage/count_usage/model_estimates
 * and the /usage route. The body keeps EVERY legacy field (old APKs parse
 * them) and adds the display-safe contract from the README: plan identity,
 * the window, one allowance pool, per-model remaining messages/images, and
 * today's counts. No prices are ever rendered by the app.
 *
 * Spend = max(sum of LiteLLM spend logs, the hook's exact per-user counter);
 * when no live window exists the window is anchored at the earliest request
 * found. Free users also honour the monthly backstop.
 */

export const IMAGE_CALL_TYPES = new Set([
  "image_generation",
  "aimage_generation",
  "image_edit",
  "aimage_edit",
  "image_variation",
  "aimage_variation",
]);

export interface UsageTodayByModel {
  requests: number;
  input_tokens: number;
  output_tokens: number;
  images: number;
  via_auto: number;
}

export interface UsageToday {
  requests: number;
  input_tokens: number;
  output_tokens: number;
  images: number;
  auto_requests: number;
  by_model: Record<string, UsageTodayByModel>;
}

export interface UsagePool {
  class: "all";
  remaining_fraction: number;
  resets_at: string;
  slow_mode: boolean;
}

export interface UsageModelEntry {
  id: string;
  name: string;
  kind: "chat" | "image";
  auto: boolean;
  estimate: "typical" | "conservative";
  members?: string[];
  priced: boolean;
  slow_mode: boolean;
  remaining_messages?: number | null;
  remaining_images?: number | null;
  /** Back-compat fields read by current app builds (never rendered). */
  model: string;
  input_cost_per_token: unknown;
  output_cost_per_token: unknown;
  remaining_pct: number;
}

export interface UsageBody {
  tier: string;
  is_paid: boolean;
  daily_spent_usd: number;
  daily_budget_usd: number;
  daily_remaining_usd: number;
  month_free_spent_usd: number;
  month_free_cap_usd: number;
  requests_today: number;
  budget_window: string;
  remaining_pct: number;
  plan: string;
  plan_name: string;
  window: string;
  resets_at: string;
  today: UsageToday;
  remaining_fraction: number;
  pools: UsagePool[];
  models: UsageModelEntry[];
  /** Task 10 merges billing_enabled / plan_* / plans here. */
  [billingField: string]: unknown;
}

export interface AdminUsageDetail {
  keys: Array<Record<string, unknown>>;
  spend_usd: number;
  logged_spend_usd: number;
  hook_counter_usd: number;
  pools_usd: Pools;
  pool_state_usd: { all: { cap: number; spent: number; remaining: number } };
  slow_mode: boolean;
  window_start: string;
  remaining_usd: number;
}

interface PoolState {
  all: { cap: number; spent: number; remaining: number };
  slow_mode: boolean;
}

/** Python truthiness for `x or ""` string coercions. */
function pyStr(v: unknown): string {
  if (v === null || v === undefined || v === "" || v === 0 || v === false) return "";
  return String(v);
}

/** Python datetime.fromisoformat, naive timestamps treated as UTC. */
export function parseTime(v: unknown): Date | null {
  if (v instanceof Date) return v;
  if (typeof v !== "string" || v.trim() === "") return null;
  let text = v.trim();
  if (/[zZ]$/.test(text)) text = `${text.slice(0, -1)}+00:00`;
  text = text.replace(" ", "T");
  // normalize +0000 → +00:00
  const tz = text.match(/([+-])(\d{2})(\d{2})$/);
  if (tz !== null) {
    text = `${text.slice(0, -5)}${tz[1]}${tz[2]}:${tz[3]}`;
  }
  if (!/[+-]\d{2}:\d{2}$/.test(text)) {
    if (!text.includes("T")) text += "T00:00:00";
    text += "Z";
  }
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? null : new Date(ms);
}

/** Spend logs store the hashed key; legacy raw sk- ids are hashed here. */
export function tokenId(keyId: string): string {
  return keyId.startsWith("sk-")
    ? createHash("sha256").update(keyId).digest("hex")
    : keyId;
}

function dateStr(d: Date): string {
  return d.toISOString().slice(0, 10);
}

/** mint.py _spend_logs: one key's rows since `start`, fail-soft. */
async function spendLogsFor(
  deps: MintDeps,
  keyId: string,
  start: Date,
  now: Date,
): Promise<SpendLogRow[]> {
  const token = tokenId(keyId);
  const rows = await deps.litellm.spendLogs({
    key: token,
    start_date: dateStr(start),
    end_date: dateStr(new Date(now.getTime() + 86_400_000)),
  });
  const out: SpendLogRow[] = [];
  for (const row of rows) {
    if (row.api_key !== null && row.api_key !== undefined && row.api_key !== "" && row.api_key !== token) {
      continue;
    }
    const t = parseTime(row.startTime ?? row.start_time);
    if (t !== null && t.getTime() < start.getTime()) continue;
    out.push(row);
  }
  return out;
}

/**
 * (public model id, via_auto) for one spend-log row. Requests made with
 * `auto` are attributed to the member model LiteLLM actually used when it
 * logged it, else to `auto`.
 */
export function attributeRow(row: SpendLogRow, cat: Catalog): [string, boolean] {
  const meta =
    typeof row.metadata === "object" && row.metadata !== null && !Array.isArray(row.metadata)
      ? (row.metadata as Record<string, unknown>)
      : {};
  const group = pyStr(row.model_group ?? meta.model_group);
  let under = pyStr(row.model);
  if (!under && row.model_id) {
    under = cat.dep_underlying[String(row.model_id)] ?? "";
  }
  if (group && cat.auto_groups.has(group)) {
    return [publicFor(cat, under) ?? AUTO_MODEL, true];
  }
  if (group in cat.groups) {
    return [group, false];
  }
  const pub = publicFor(cat, under);
  if (pub !== null) {
    return [pub, false];
  }
  if (under in cat.groups) {
    return [under, false];
  }
  return [group || under || "unknown", false];
}

/**
 * (window counts, logged spend USD, measured avg image tokens per model).
 * `autoHits` (served model → n) adds requests the hook rewrote from auto,
 * which LiteLLM logs under the member's name — capped at the rows that were
 * not already attributed to auto.
 */
export function countUsage(
  rows: SpendLogRow[],
  cat: Catalog,
  _settings: Settings,
  autoHits?: Record<string, string> | null,
): { today: UsageToday; spend: number; measured: Record<string, number> } {
  const today: UsageToday = {
    requests: 0,
    input_tokens: 0,
    output_tokens: 0,
    images: 0,
    auto_requests: 0,
    by_model: {},
  };
  let spend = 0;
  const imgTokens: Record<string, number[]> = {};

  for (const row of rows) {
    if (pyStr(row.status ?? "success").toLowerCase() === "failure") continue;
    const [mid, viaAuto] = attributeRow(row, cat);
    const callType = pyStr(row.call_type);
    const isImage = IMAGE_CALL_TYPES.has(callType) || groupKind(cat.groups[mid]) === "image";
    const pin = intOr(row.prompt_tokens, 0);
    const pout = intOr(row.completion_tokens, 0);
    spend += floatOr(row.spend, 0);

    let bm = today.by_model[mid];
    if (bm === undefined) {
      bm = { requests: 0, input_tokens: 0, output_tokens: 0, images: 0, via_auto: 0 };
      today.by_model[mid] = bm;
    }
    for (const d of [today, bm]) {
      d.requests += 1;
      d.input_tokens += pin;
      d.output_tokens += pout;
      if (isImage) d.images += 1;
    }
    if (viaAuto) {
      today.auto_requests += 1;
      bm.via_auto += 1;
    }
    if (isImage && pout > 0) {
      (imgTokens[mid] ??= []).push(pout);
    }
  }

  for (const [served, raw] of Object.entries(autoHits ?? {})) {
    const mid = served in cat.groups ? served : (publicFor(cat, served) ?? served);
    const bm = today.by_model[mid];
    if (bm === undefined) continue;
    const add = Math.max(0, Math.min(intOr(raw, 0), bm.requests - bm.via_auto));
    bm.via_auto += add;
    today.auto_requests += add;
  }

  const measured: Record<string, number> = {};
  for (const [m, values] of Object.entries(imgTokens)) {
    measured[m] = values.reduce((a, b) => a + b, 0) / values.length;
  }
  return { today, spend, measured };
}

/**
 * Estimated USD per typical message (chat) or per image, at THIS model's
 * LiteLLM price (the most expensive deployment when a name has several).
 */
export function unitCost(
  g: CatalogGroup,
  settings: Settings,
  measured: Record<string, number>,
): number | null {
  if (groupKind(g) === "image") {
    if (g.per_image.length > 0) return Math.max(...g.per_image);
    if (g.outputs.length > 0) {
      const toks = measured[g.id] || settings.est_image_tokens;
      return Math.max(...g.outputs) * toks;
    }
    return null;
  }
  const cost =
    (g.inputs.length > 0 ? Math.max(...g.inputs) : 0) * settings.est_input_tokens +
    (g.outputs.length > 0 ? Math.max(...g.outputs) : 0) * settings.est_output_tokens;
  return cost > 0 ? cost : null;
}

/**
 * Per-model remaining messages/images from the ONE allowance, at THAT model's
 * price. Auto is priced at its most expensive member (conservative); when the
 * plan routes auto to auto_oss_members, those are its members. A public alias
 * with no LiteLLM group of its own (the image studio alias) is priced at the
 * dearest private image backend.
 */
export function modelEstimates(
  cat: Catalog,
  st: PoolState,
  settings: Settings,
  measuredImg: Record<string, number> | null | undefined,
  remainingFraction: number,
  autoMembers?: string[] | null,
  visible?: string[] | null,
): UsageModelEntry[] {
  const measured = measuredImg ?? {};
  const groups = cat.groups;
  const rem = Math.max(0, st.all.remaining);
  const names = visible === undefined || visible === null ? Object.keys(groups) : [...new Set(visible)];
  const shown = new Set(names);
  const out: UsageModelEntry[] = [];

  for (const gid of names) {
    const g = groups[gid];
    const isAuto = cat.auto_groups.has(gid);
    let kind: "chat" | "image";
    let entry: UsageModelEntry;
    let legacy: { input_cost_per_token: unknown; output_cost_per_token: unknown };
    let cost: number | null;

    if (g === undefined) {
      kind = "image";
      const privateGroups = Object.entries(groups)
        .filter(([name, x]) => !shown.has(name) && groupKind(x) === "image")
        .map(([, x]) => x);
      const costs = privateGroups
        .map((x) => unitCost(x, settings, measured))
        .filter((c): c is number => c !== null);
      cost = costs.length > 0 ? Math.max(...costs) : null;
      entry = { id: gid, name: gid, kind, auto: false, estimate: "conservative" } as UsageModelEntry;
      legacy = { input_cost_per_token: null, output_cost_per_token: null };
    } else {
      kind = isAuto ? "chat" : groupKind(g);
      entry = {
        id: gid,
        name: g.name,
        kind,
        auto: isAuto,
        estimate: "typical",
      } as UsageModelEntry;
      legacy = g.legacy;
      if (isAuto) {
        let members = (autoMembers ?? []).filter((m) => m in groups);
        if (members.length === 0) {
          members = [
            ...new Set(
              g.underlying
                .map((u) => publicFor(cat, u))
                .filter((p): p is string => p !== null && p in groups && !cat.auto_groups.has(p)),
            ),
          ];
        }
        const costs = members
          .map((m) => unitCost(groups[m]!, settings, measured))
          .filter((c): c is number => c !== null);
        if (!autoMembers) {
          const own = unitCost(g, settings, measured);
          if (own !== null) costs.push(own);
        }
        cost = costs.length > 0 ? Math.max(...costs) : null;
        entry.estimate = "conservative";
        entry.members = [...members].sort();
      } else {
        cost = unitCost(g, settings, measured);
      }
    }

    const priced = cost !== null && cost > 0;
    entry.priced = priced;
    entry.slow_mode = Boolean(st.slow_mode);
    const remaining = priced ? Math.floor(rem / (cost as number) + 1e-9) : null;
    if (kind === "image") {
      entry.remaining_images = remaining;
    } else {
      entry.remaining_messages = remaining;
    }
    // Back-compat fields read by current app builds. Not for display.
    entry.model = gid;
    entry.input_cost_per_token = legacy.input_cost_per_token;
    entry.output_cost_per_token = legacy.output_cost_per_token;
    entry.remaining_pct = pyRound(remainingFraction, 4);
    out.push(entry);
  }

  out.sort((a, b) => {
    const autoA = a.auto ? 0 : 1;
    const autoB = b.auto ? 0 : 1;
    if (autoA !== autoB) return autoA - autoB;
    const chatA = a.kind === "chat" ? 0 : 1;
    const chatB = b.kind === "chat" ? 0 : 1;
    if (chatA !== chatB) return chatA - chatB;
    const nameA = a.name.toLowerCase();
    const nameB = b.name.toLowerCase();
    return nameA < nameB ? -1 : nameA > nameB ? 1 : 0;
  });
  return out;
}

/**
 * (public /usage body, admin-only detail). Spend comes from LiteLLM for ALL
 * of the user's keys (android + web) plus the hook's per-user counter.
 */
export async function computeUsage(
  deps: MintDeps,
  uid: string,
): Promise<{ body: UsageBody; detail: AdminUsageDetail }> {
  const s = await getSettings({ db: deps.db });
  const plan = await planFor(deps, uid, s);
  const freeDaily = await userFreeDaily({ db: deps.db }, uid);
  const override = await getOverride({ db: deps.db }, uid);
  const pools = userPools(s, plan, freeDaily, override);
  const keys = await poolUserKeyIds(deps, uid);
  const keyDetail: Array<Record<string, unknown>> = [];
  let rows: SpendLogRow[] = [];
  const now = new Date((deps.clock ?? (() => new Date()))().getTime());

  const liveStart = await currentWindowStart(deps, uid, pools);
  // No live window: look back one window length; the window then starts at
  // the earliest request found (or now when there is none).
  const since = liveStart ?? new Date(now.getTime() - pools.window_hours * 3600_000);

  for (const [ns, kid] of Object.entries(keys)) {
    const info = await deps.litellm.keyInfo(kid);
    const d: Record<string, unknown> = { platform: ns ? "web" : "android", present: true };
    if (info !== null) {
      d.spend_usd = floatOr(info.spend, 0);
      d.max_budget_usd = info.max_budget ?? null;
      d.budget_duration = info.budget_duration ?? null;
      d.budget_reset_at = info.budget_reset_at ?? null;
      d.rpm_limit = info.rpm_limit ?? null;
      d.max_parallel_requests = info.max_parallel_requests ?? null;
      d.blocked = Boolean(info.blocked);
    }
    keyDetail.push(d);
    rows.push(...(await spendLogsFor(deps, kid, since, now)));
  }

  let start = liveStart;
  if (start === null) {
    const times = rows
      .map((r) => parseTime(r.startTime ?? r.start_time))
      .filter((t): t is Date => t !== null);
    const firstUse =
      times.length > 0 ? new Date(Math.min(...times.map((t) => t.getTime()))) : now;
    start = (await windowBounds(deps, uid, pools, { firstUse })).start;
    const anchor = start;
    rows = rows.filter((r) => {
      const t = parseTime(r.startTime ?? r.start_time) ?? now;
      return t.getTime() >= anchor.getTime();
    });
  }
  const resetsAt = new Date(start.getTime() + pools.window_hours * 3600_000);

  const cat = await catalogFor(deps);
  const monthFreeSpent = Object.keys(keys).length > 0 ? await monthSpent(deps, uid) : 0;
  const autoHits = await deps.redis.hgetall(poolKeys(uid).auto);
  const { today, spend: logSpend, measured } = countUsage(rows, cat, s, autoHits);
  const counters = await hookSpend(deps, uid);
  // The hook's counter is exact and real time; spend logs may lag. Take
  // whichever is ahead.
  const spent = Math.max(logSpend, counters);
  const monthCap = await freeCapUsd(deps, uid);
  const capLeft = plan.id === "free" ? monthCap - monthFreeSpent : null;
  const st = poolState(pools, spent, capLeft);
  if (st.slow_mode || (await poolInSlowMode(deps, uid))) {
    await poolSyncSlowMode(deps, uid, st.slow_mode, resetsAt);
  }

  const resetsIso = isoUtc(resetsAt);
  const budget = st.all.cap;
  const remaining = st.all.remaining;
  const fraction = budget > 0 ? pyRound(Math.min(1, remaining / budget), 4) : 0;
  const window = windowStr(pools.window_hours);

  const body: UsageBody = {
    tier: storedTier(plan),
    is_paid: plan.id !== "free",
    // Back-compat / internal USD (never rendered by the app).
    daily_spent_usd: pyRound6(spent),
    daily_budget_usd: pyRound6(budget),
    daily_remaining_usd: pyRound6(remaining),
    month_free_spent_usd: pyRound6(monthFreeSpent),
    month_free_cap_usd: pyRound6(monthCap),
    requests_today: today.requests,
    budget_window: window,
    remaining_pct: fraction,
    // Display-safe fields (no money).
    plan: plan.id,
    plan_name: plan.name,
    window,
    resets_at: resetsIso,
    today,
    remaining_fraction: fraction,
    pools: [
      {
        class: "all",
        remaining_fraction: fraction,
        resets_at: resetsIso,
        slow_mode: Boolean(st.slow_mode),
      },
    ],
    models: modelEstimates(
      cat,
      st,
      s,
      measured,
      fraction,
      pools.auto_oss ? s.auto_oss_members.map((m) => m.model) : null,
      availableModels(deps)
        .map((r) => r.model)
        .filter(Boolean),
    ),
  };

  const detail: AdminUsageDetail = {
    keys: keyDetail,
    spend_usd: pyRound6(spent),
    logged_spend_usd: pyRound6(logSpend),
    hook_counter_usd: counters,
    pools_usd: pools,
    pool_state_usd: { all: st.all },
    slow_mode: Boolean(st.slow_mode),
    window_start: isoUtc(start),
    remaining_usd: pyRound6(remaining),
  };
  return { body, detail };
}

function headerValue(v: string | string[] | undefined): string {
  if (typeof v === "string") return v;
  if (Array.isArray(v)) return v[0] ?? "";
  return "";
}

/**
 * POST /usage on the PUBLIC app. Identity comes from Task 6's verifier seam
 * (deps.verifyIdentity); the 401 shapes are the legacy FastAPI contract. The
 * body is cached for USAGE_CACHE_S seconds under usagecache:{uid} — window
 * resets and dropUsageCache delete it.
 */
export function registerUsageRoutes(
  publicApp: FastifyInstance,
  deps: MintDeps,
  billing?: BillingService,
): void {
  publicApp.post("/usage", async (request, reply) => {
    const authorization = headerValue(request.headers.authorization);
    if (!/^bearer /i.test(authorization)) {
      return reply.code(401).send({ detail: "missing bearer id token" });
    }
    const appcheck = headerValue(request.headers["x-firebase-appcheck"]);
    if (deps.env.appcheckEnabled && appcheck === "") {
      return reply.code(401).send({ detail: "missing app check token" });
    }
    const identity = await deps.verifyIdentity({
      authorization,
      appcheck,
      xff: headerValue(request.headers["x-forwarded-for"]),
      xRealIp: headerValue(request.headers["x-real-ip"]),
    });
    const uid = identity.uid;
    const cacheKey = `usagecache:${uid}`;

    if (deps.env.usageCacheS > 0) {
      const cached = await deps.redis.get(cacheKey);
      if (cached) {
        try {
          return reply.send(JSON.parse(cached));
        } catch {
          // corrupt cache entry → recompute below
        }
      }
    }
    const { body } = await computeUsage(deps, uid);
    // Task 10 billing merge point: payload = {...body, ...usageFields(uid)}
    // (billing_enabled / plan_expires_at / plan_auto_renews / plan_product_id
    // / plans — exactly the server/billing README contract).
    const payload: UsageBody =
      billing === undefined ? body : { ...body, ...(await billing.usageFields(uid)) };
    if (deps.env.usageCacheS > 0) {
      await deps.redis.set(cacheKey, JSON.stringify(payload), "EX", deps.env.usageCacheS);
    }
    return reply.send(payload);
  });
}
