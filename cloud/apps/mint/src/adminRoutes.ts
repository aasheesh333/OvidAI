import { timingSafeEqual } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { billingRemote, billingUsers, plansRepo } from "@ovid/db";
import { pyNumStr } from "@ovid/money";
import { audit, AUDIT_LIST } from "./adminAudit.js";
import { ADMIN_CONSOLE_HTML } from "./adminConsole.html.js";
import { setKeyBlocked } from "./antiAbuse.js";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { catalogFor, groupKind, publicFor } from "./catalog.js";
import type { MintEnv } from "./env.js";
import { requireInternalSignature } from "./internalAuth.js";
import { createProjection } from "./projection.js";
import {
  SCALARS,
  findPlan,
  reconcileCanonicalPlans,
  storedTier,
  validateMembers,
  validatePlan,
  validateSettings,
  type PlanData,
  type PoolsOverride,
  type Settings,
} from "./planMath.js";
import {
  ProjectionPublishError,
  getSettings,
  storeSettings,
  userFreeDaily,
} from "./settings.js";
import { sweepSlowMode } from "./slowMode.js";
import { computeUsage, unitCost, withAppPlanFields } from "./usage.js";
import {
  dropUsageCache,
  isoUtc,
  planFor,
  poolUserKeyIds,
  reapplyUser,
  resetWindowUser,
  withBillingAccountWrite,
  currentBillingProjectionGeneration,
  StaleBillingAccountWriteError,
  type ReapplyResult,
} from "./windows.js";

/**
 * The owner admin surface — the port of mint.py's /admin block
 * (mint.py:1577-2017) plus the console page (adminConsole.html.ts). Every
 * route is registered on the ADMIN app (port 8092): Caddy never routes
 * /admin, so the console is reachable only via localhost / an SSH tunnel.
 *
 * AUTH: OVID_ADMIN_MASTER_KEY (env.adminMasterKey) as a Bearer token —
 * requireAdmin fires BEFORE any side effect on every route (the ladder
 * order Python pins). The console PAGE itself needs no key; it is a pure
 * client of this JSON API.
 *
 * DURABILITY (Ruling Q4 — the delta from Python's Redis-direct writes):
 * tier / overrides / bans are written to Postgres first, then re-published
 * to the db2 projection (createProjection), then re-applied to LiteLLM.
 * Settings changes flow through Task 4's storeSettings (validate → Postgres
 * → db2 re-publish) and are re-applied to every key by default.
 */

export const REAPPLY_STATUS_KEY = "config:reapply_status";
export const RESET_STATUS_KEY = "config:reset_status";

const BAN_IP_TTL_S = 30 * 24 * 3600;
const PROGRESS_EVERY = 25;

// ── auth ─────────────────────────────────────────────────────────────────────

/**
 * mint.py _require_admin with the plan's pin: the OWNER token is
 * OVID_ADMIN_MASTER_KEY. Constant-time on equal-length inputs; the length
 * guard keeps timingSafeEqual from throwing (and leaks only the length,
 * which the guard's early exit already reveals).
 */
export function requireAdmin(env: MintEnv, authorization: string): void {
  if (!authorization || !authorization.toLowerCase().startsWith("bearer ")) {
    throw new HttpContractError(401, "missing authorization");
  }
  // Python split(" ", 1)[1]: everything after the FIRST space
  const token = authorization.slice(authorization.indexOf(" ") + 1);
  const expected = Buffer.from(env.adminMasterKey, "utf8");
  const got = Buffer.from(token, "utf8");
  if (got.length !== expected.length || !timingSafeEqual(got, expected)) {
    throw new HttpContractError(403, "not admin");
  }
}

function headerValue(v: string | string[] | undefined): string {
  if (typeof v === "string") return v;
  if (Array.isArray(v)) return v[0] ?? "";
  return "";
}

/** mint.py _request_ip: first XFF hop, else the socket peer. */
function requestIp(request: FastifyRequest): string {
  const xff = headerValue(request.headers["x-forwarded-for"]);
  if (xff !== "") {
    return xff.split(",")[0]!.trim();
  }
  return request.ip || "unknown";
}

// ── body coercion (strict where a wrong type would change behaviour) ───────

function optStr(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

/**
 * I1: a mutating admin route requires a JSON OBJECT. A missing body, JSON
 * null, a scalar or an array is a client error — never an implicit "{}".
 * This is what stops `POST /admin/reset-window` with no body from becoming a
 * GLOBAL reset (Python's ResetAction required an object and answered 422).
 */
function requireBodyObject(request: FastifyRequest): Record<string, unknown> {
  const body = request.body;
  if (typeof body === "object" && body !== null && !Array.isArray(body)) {
    return body as Record<string, unknown>;
  }
  throw new HttpContractError(400, "request body must be a JSON object");
}

/**
 * Pydantic-style bool coercion (M1): a present value must be a boolean or
 * the strings "true"/"false" — `Boolean("false") === true` is exactly the
 * bug this replaces. Anything else is a 400, never a silent truthy value.
 */
function boolField(
  body: Record<string, unknown>,
  name: string,
  dflt: boolean,
): boolean {
  const v = body[name];
  if (v === undefined || v === null) return dflt;
  if (typeof v === "boolean") return v;
  if (typeof v === "string") {
    const s = v.trim().toLowerCase();
    if (s === "true") return true;
    if (s === "false") return false;
  }
  throw new HttpContractError(400, `${name} must be true or false`);
}

/**
 * Pydantic-style float coercion (M1): a PRESENT numeric field must parse.
 * Previously `{"daily_usd":"abc"}` was silently ignored and the route
 * answered 200 without changing anything.
 */
function numField(body: Record<string, unknown>, name: string): number | null {
  const v = body[name];
  if (v === undefined || v === null) return null;
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    if (!Number.isNaN(n)) return n;
  }
  throw new HttpContractError(400, `${name} must be a number`);
}

/** reapply flag: body first (Python's payload.pop), then ?reapply=false. */
function reapplyFlag(request: FastifyRequest, body: Record<string, unknown>): boolean {
  if (body.reapply !== undefined) {
    return boolField(body, "reapply", true);
  }
  const q = request.query as Record<string, unknown> | undefined;
  if (q?.reapply !== undefined) {
    return q.reapply !== "false" && q.reapply !== false;
  }
  return true;
}

// ── user state (Postgres is the authority; Redis is the live projection) ────

interface UserRow {
  tier: string;
  email: string | null;
  banned: boolean;
  bannedReason: string | null;
}

async function userRow(deps: MintDeps, uid: string): Promise<UserRow | null> {
  const rows = (await deps.db.$client`
    SELECT tier, email, banned_at IS NOT NULL AS banned, banned_reason
    FROM users WHERE uid = ${uid}`) as Array<{
    tier: string;
    email: string | null;
    banned: boolean;
    banned_reason: string | null;
  }>;
  const raw = rows[0];
  if (raw === undefined) {
    return null;
  }
  return {
    tier: raw.tier,
    email: raw.email,
    banned: Boolean(raw.banned),
    bannedReason: raw.banned_reason,
  };
}

export interface AdminUserState {
  tier: string;
  plan: string;
  daily_usd_override: string | null;
  monthly_cap_override: string | null;
  pools_override: PoolsOverride | null;
  banned: string | null;
}

/** mint.py _user_state — Postgres authority, with a Redis-only ban merged in. */
async function userState(deps: MintDeps, uid: string): Promise<AdminUserState> {
  const [s, row, override, redisBan] = await Promise.all([
    getSettings({ db: deps.db }),
    userRow(deps, uid),
    plansRepo.getOverride(deps.db, uid),
    deps.redis.get(`user:${uid}:banned`),
  ]);
  const plan = findPlan(s, row?.tier ?? null);
  // I2: a Redis-only ban (an auto-ban whose Postgres write failed, or a ban
  // imported from the Python install) is still a ban. Export/audit must not
  // report it as unbanned just because users.banned_at is NULL.
  const banned =
    row?.banned === true
      ? (row.bannedReason ?? "admin")
      : redisBan !== null && redisBan !== ""
        ? redisBan
        : null;
  return {
    tier: storedTier(plan),
    plan: plan.id,
    daily_usd_override: override?.dailyUsd ?? null,
    monthly_cap_override: override?.monthlyCapUsd ?? null,
    pools_override: override?.pools ?? null,
    banned,
  };
}

// ── pools override validation (mint.py _validate_pool_override) ─────────────

const OVERRIDE_FIELDS = new Set(["mult", "window_hours", "slow_mode", "auto_oss"]);
const BOOL_FIELDS = new Set(["slow_mode", "auto_oss"]);
/** ovid_plans PLAN_NUMBERS for the overridable numeric fields. */
const OVERRIDE_NUMBERS: Record<string, [number, number]> = {
  mult: [0, 100000],
  window_hours: [1, 24 * 366],
};

/** ovid_plans._bounded — throws with Python's exact messages. */
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

function validatePoolOverride(p: Record<string, unknown>): PoolsOverride {
  const out: Record<string, unknown> = {};
  for (const [f, v] of Object.entries(p)) {
    if (!OVERRIDE_FIELDS.has(f)) {
      throw new HttpContractError(400, `unknown override field '${f}'`);
    }
    if (v === null || v === undefined) continue;
    if (BOOL_FIELDS.has(f)) {
      if (typeof v !== "boolean") {
        throw new HttpContractError(400, `${f} must be true or false`);
      }
      out[f] = v;
      continue;
    }
    const [lo, hi] = OVERRIDE_NUMBERS[f]!;
    try {
      out[f] = pyBounded(f, v, lo, hi);
    } catch (err) {
      throw new HttpContractError(400, (err as Error).message);
    }
  }
  if ("window_hours" in out) {
    out.window_hours = Math.trunc(out.window_hours as number);
  }
  return out as PoolsOverride;
}

// ── run-over-users machinery (mint.py _run_over_users / run_for_everyone) ──

interface RunTotal {
  users: number;
  keys: number;
  errors: number;
}

function clockNow(deps: MintDeps): Date {
  return new Date((deps.clock ?? (() => new Date()))().getTime());
}

async function runOverUsers(
  deps: MintDeps,
  statusKey: string,
  uids: string[],
  fn: (uid: string) => Promise<ReapplyResult>,
): Promise<RunTotal> {
  const total: RunTotal = { users: 0, keys: 0, errors: 0 };
  const write = (state: string, done: number): Promise<unknown> =>
    deps.redis.set(
      statusKey,
      JSON.stringify({ state, total: uids.length, done, ...total, at: isoUtc(clockNow(deps)) }),
    );
  await write("running", 0);
  for (let i = 0; i < uids.length; i++) {
    const res = await fn(uids[i]!);
    total.users += 1;
    total.keys += res?.keys ?? 0;
    total.errors += res?.errors ?? 0;
    if ((i + 1) % PROGRESS_EVERY === 0) {
      await write("running", i + 1);
    }
  }
  await write("done", uids.length);
  return total;
}

export type ReapplyAllResult =
  | { mode: "sync"; users: number; keys: number; errors: number }
  | { mode: "background"; users: number };

/**
 * Re-apply budgets to every key: mint.py's reapply_everyone when no uids are
 * given (sync while ≤ REAPPLY_SYNC_MAX, else a background promise chain with
 * progress in config:reapply_status every 25 users) and reapply_all (always
 * sync) for an explicit uid list. Background work is spawned with
 * setImmediate so the route answers immediately; errors only log.
 */
export async function reapplyAll(
  deps: MintDeps,
  uids?: string[] | null,
): Promise<ReapplyAllResult> {
  const list = uids ?? (await plansRepo.mintUids(deps.db));
  const run = (): Promise<RunTotal> =>
    runOverUsers(deps, REAPPLY_STATUS_KEY, list, (uid) => reapplyUser(deps, uid));
  if (uids === undefined && list.length > deps.env.reapplySyncMax) {
    setImmediate(() => {
      run().catch((err: unknown) => {
        console.log(`[mint] background reapply: ${errorName(err)}`);
      });
    });
    return { mode: "background", users: list.length };
  }
  return { mode: "sync", ...(await run()) };
}

export interface CanonicalResyncResult {
  ok: boolean;
  status: "ok" | "degraded";
  changed: boolean;
  plans: PlanData[];
  projection: {
    redis: "ok" | "failed";
    litellm: "ok" | "degraded";
    errors: number;
  };
}

/**
 * Migration 0025 owns legacy-id movement. This idempotent operator resync only
 * canonicalizes existing rows, then proves the derived Redis/LiteLLM views.
 * A projection failure is explicitly degraded: durable Postgres is never
 * misreported as a rejected write or a fully successful projection.
 */
export async function resyncCanonicalPlans(
  deps: MintDeps,
  opts: { ip?: string } = {},
): Promise<CanonicalResyncResult> {
  const before = await getSettings({ db: deps.db });
  const desired = reconcileCanonicalPlans(before.plans).map((plan) => validatePlan(plan));
  const changed = JSON.stringify(desired) !== JSON.stringify(before.plans);
  let redisStatus: "ok" | "failed" = "ok";
  try {
    if (changed) {
      await storeSettings({ db: deps.db, redis: deps.redis }, { ...before, plans: desired });
    } else {
      await createProjection({ db: deps.db, redis: deps.redis }).publishSettings();
    }
  } catch (error) {
    if (changed && !(error instanceof ProjectionPublishError)) throw error;
    redisStatus = "failed";
  }

  let litellmStatus: "ok" | "degraded" = "ok";
  let errors = 0;
  try {
    // An explicit uid list is always synchronous, so the result really proves
    // every LiteLLM projection instead of merely scheduling background work.
    const result = await reapplyAll(deps, await plansRepo.mintUids(deps.db));
    if (result.mode === "sync") errors = result.errors;
    if (errors > 0) litellmStatus = "degraded";
  } catch {
    litellmStatus = "degraded";
    errors = Math.max(1, errors);
  }
  const current = await getSettings({ db: deps.db });
  const ok = redisStatus === "ok" && litellmStatus === "ok";
  const result: CanonicalResyncResult = {
    ok,
    status: ok ? "ok" : "degraded",
    changed,
    plans: current.plans,
    projection: { redis: redisStatus, litellm: litellmStatus, errors },
  };
  await audit(deps, "plan-resync", {
    target: "canonical-plans",
    before,
    after: { ...current, projection: result.projection },
    ip: opts.ip,
  });
  return result;
}

// ── settings application (mint.py _apply_settings + _check_members_exist) ──

/** auto_oss_members must be real LiteLLM model names (/model/info). */
async function checkMembersExist(
  deps: MintDeps,
  members: { model: string; weight: number }[],
): Promise<void> {
  if (!members || members.length === 0) {
    return;
  }
  const cat = await catalogFor(deps);
  if (Object.keys(cat.groups).length === 0) {
    throw new HttpContractError(
      400,
      "cannot validate auto_oss_members: LiteLLM /model/info unavailable",
    );
  }
  const unknown = members.filter((m) => !(m.model in cat.groups)).map((m) => m.model);
  if (unknown.length > 0) {
    throw new HttpContractError(400, `not LiteLLM models: ${unknown.join(", ")}`);
  }
  if (members.some((m) => cat.auto_groups.has(m.model))) {
    throw new HttpContractError(400, "auto_oss_members cannot contain the auto group");
  }
}

interface ApplySettingsResult {
  ok: boolean;
  accepted: boolean;
  settings: Settings;
  reapplied: ReapplyAllResult | { mode: "skipped" };
}

async function applySettings(
  deps: MintDeps,
  request: FastifyRequest,
  changes: Record<string, unknown>,
  reapply: boolean,
  action: string,
  target: unknown = "global",
): Promise<ApplySettingsResult> {
  const before = await getSettings({ db: deps.db });
  const merged: Record<string, unknown> = { ...before };
  for (const [k, v] of Object.entries(changes)) {
    if (v === null || v === undefined) continue;
    // M11: `in` accepts prototype keys ("toString"/"constructor") and would
    // silently store them; only an own setting name is valid.
    if (!Object.hasOwn(merged, k)) {
      throw new HttpContractError(400, `unknown setting '${k}'`);
    }
    merged[k] = v;
  }
  if (changes.auto_oss_members !== undefined && changes.auto_oss_members !== null) {
    let members: { model: string; weight: number }[];
    try {
      members = validateMembers(changes.auto_oss_members);
    } catch (err) {
      throw new HttpContractError(400, (err as Error).message);
    }
    await checkMembersExist(deps, members);
  }

  // Validation errors are CLIENT errors (400). Postgres/projection failures
  // are infrastructure errors and must never masquerade as a rejected write
  // (I3) — and never leak the raw driver message to the wire.
  try {
    validateSettings(merged as unknown as Settings);
  } catch (err) {
    throw new HttpContractError(400, (err as Error).message);
  }

  let after: Settings;
  try {
    // validate → Postgres (authority) → db2 re-publish
    after = await storeSettings({ db: deps.db, redis: deps.redis }, merged as unknown as Settings);
  } catch (err) {
    if (err instanceof ProjectionPublishError) {
      // Postgres committed. Audit the durable change (with a degraded marker
      // in the log) and answer a sanitized 500 — the operator must not read
      // "rejected" and keep enforcing the old value.
      console.log(
        `[mint] settings projection failed after postgres commit: ${errorName(err.cause)}`,
      );
      const durable = await getSettings({ db: deps.db });
      await audit(deps, action, {
        target,
        before,
        after: { ...durable, projection_error: "redis projection failed" },
        ip: requestIp(request),
      });
      throw new HttpContractError(
        500,
        "settings saved but the redis projection failed; retry or resync",
      );
    }
    console.log(`[mint] settings store failed: ${errorName(err)}`);
    throw new HttpContractError(500, "could not save settings");
  }
  const result = reapply ? await reapplyAll(deps) : { mode: "skipped" as const };
  if (result.mode === "sync" && result.errors > 0) {
    await audit(deps, action, {
      target,
      before,
      after: { ...after, projection_error: "LiteLLM projection unresolved" },
      ip: requestIp(request),
    });
    throw new HttpContractError(503, "settings saved but the LiteLLM projection is unresolved");
  }
  await audit(deps, action, { target, before, after, ip: requestIp(request) });
  const accepted = result.mode === "background";
  return {
    ok: !accepted,
    accepted,
    settings: await getSettings({ db: deps.db }),
    reapplied: result,
  };
}

// ── routes ───────────────────────────────────────────────────────────────────

const CONSOLE_HEADERS: Record<string, string> = {
  "cache-control": "no-store",
  "x-frame-options": "DENY",
  "content-security-policy":
    "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
};

export function registerAdminRoutes(adminApp: FastifyInstance, deps: MintDeps): void {
  // M7: every admin response (JSON included) is owner data — never cache it.
  // Defense-in-depth: the listener is loopback-only, but /admin/user and
  // /admin/export carry PII/usage.
  adminApp.addHook("onSend", async (_request, reply, payload) => {
    reply.header("cache-control", "no-store");
    reply.header("x-content-type-options", "nosniff");
    return payload;
  });

  function auth(request: FastifyRequest): void {
    requireAdmin(deps.env, headerValue(request.headers.authorization));
  }

  async function statusJson(key: string): Promise<unknown> {
    const raw = await deps.redis.get(key);
    if (raw === null) {
      return { state: "never" };
    }
    try {
      return JSON.parse(raw);
    } catch {
      return { state: "never" };
    }
  }

  // Signed, read-only gateway projection. It is registered only on this admin
  // listener and never on publicApp; the HMAC binds method, path, uid and time.
  adminApp.get("/internal/billing/entitlement", async (request, reply) => {
    const query = (request.query ?? {}) as Record<string, unknown>;
    const uid = typeof query.uid === "string" ? query.uid.trim() : "";
    if (uid === "" || uid.length > 200) {
      throw new HttpContractError(400, "uid is required");
    }
    const now = Math.floor((deps.clock?.() ?? new Date()).getTime() / 1000);
    requireInternalSignature(deps, request, "/internal/billing/entitlement", uid, now);
    if (deps.billing === undefined) {
      throw new HttpContractError(503, "billing_unavailable");
    }
    const entitlement = await deps.billing.entitlement(uid);
    return reply.send({ entitlement });
  });

  // ---- unresolved remote mutation recovery (owner only) ----

  adminApp.get("/admin/billing/remote-operations", async (request) => {
    auth(request);
    const query = request.query as Record<string, unknown> | undefined;
    const uid = typeof query?.uid === "string" && query.uid.trim() !== ""
      ? query.uid.trim()
      : undefined;
    const operations = await billingRemote.listUnresolved(deps.db, uid);
    return {
      operations: operations.map((operation) => ({
        id: operation.id,
        uid: operation.uid,
        generation: operation.generation,
        kind: operation.kind,
        effect: operation.effect ?? "update",
        target: operation.target,
        created_target: operation.createdTarget ?? null,
        phase: operation.phase ?? "prepared",
        attempts: operation.attempts ?? 0,
        updated_at: operation.updatedAt,
      })),
    };
  });

  adminApp.post("/admin/billing/remote-operations/drain", async (request, reply) => {
    auth(request);
    const body = requireBodyObject(request);
    const uid = optStr(body.uid)?.trim() ?? "";
    const operationId = optStr(body.operation_id)?.trim() ?? "";
    if (uid === "" || operationId === "") throw new HttpContractError(400, "uid and operation_id required");
    if (body.confirmation !== "remote-request-drained") {
      throw new HttpContractError(400, "external remote-request-drained confirmation required");
    }
    await withBillingAccountWrite(deps, uid, async () => {
      const generation = currentBillingProjectionGeneration();
      if (generation === undefined) throw new StaleBillingAccountWriteError();
      if (!(await billingRemote.markDrained(deps.db, uid, operationId, generation))) {
        throw new HttpContractError(409, "remote operation is not pending uncertain work");
      }
    });
    await audit(deps, "billing-remote-drain", {
      target: { uid, operation_id: operationId },
      after: { retry_required: true },
      ip: requestIp(request),
    });
    // Retirement is not remote applied-state proof. The latest caller must
    // retry; only that latest desired operation may be sent after this point.
    return reply.code(202).send({ drained: true, retry_required: true });
  });

  // ---- settings ----

  adminApp.get("/admin/settings", async (request) => {
    auth(request);
    const [settings, uids, reapplyStatus, resetStatus] = await Promise.all([
      getSettings({ db: deps.db }),
      plansRepo.mintUids(deps.db),
      deps.redis.get(REAPPLY_STATUS_KEY),
      deps.redis.get(RESET_STATUS_KEY),
    ]);
    return {
      settings,
      users: uids.length,
      scalars: Object.fromEntries(
        Object.entries(SCALARS).map(([k, spec]) => [k, { min: spec.lo, max: spec.hi }]),
      ),
      reapply_status: reapplyStatus === null ? null : tryJson(reapplyStatus),
      reset_status: resetStatus === null ? null : tryJson(resetStatus),
    };
  });

  adminApp.post("/admin/settings", async (request, reply) => {
    auth(request);
    const body = requireBodyObject(request);
    const reapply = reapplyFlag(request, body);
    const changes = { ...body };
    delete changes.reapply;
    const result = await applySettings(deps, request, changes, reapply, "settings");
    return reply.code(result.accepted ? 202 : 200).send(result);
  });

  // ---- plans as data ----

  adminApp.get("/admin/plans", async (request) => {
    auth(request);
    const settings = await getSettings({ db: deps.db });
    return { plans: settings.plans };
  });

  adminApp.post("/admin/plans/resync", async (request, reply) => {
    auth(request);
    const result = await resyncCanonicalPlans(deps, { ip: requestIp(request) });
    return reply.code(result.ok ? 200 : 503).send(result);
  });

  /** Add a plan or edit one by id: name, price, enabled, aliases, window, mult, slow, auto-oss. */
  adminApp.post("/admin/plans", async (request, reply) => {
    auth(request);
    const body = requireBodyObject(request);
    const reapply = reapplyFlag(request, body);
    const payload = { ...body };
    delete payload.reapply;
    const pid = String(payload.id ?? "");
    const current = (await getSettings({ db: deps.db })).plans;
    const found = current.find((p) => p.id === pid) ?? null;
    const newPlan = { ...(found ?? {}), ...payload } as Record<string, unknown>;
    const newList = found
      ? current.map((p) => (p.id === pid ? (newPlan as unknown as PlanData) : p))
      : [...current, newPlan as unknown as PlanData];
    const result = await applySettings(
      deps,
      request,
      { plans: newList },
      reapply,
      found ? "plan-edit" : "plan-add",
      pid,
    );
    return reply.code(result.accepted ? 202 : 200).send(result);
  });

  /** enable/disable = start/stop selling (existing users keep the plan). */
  adminApp.post("/admin/plans/:pid/:action", async (request, reply) => {
    auth(request);
    const { pid, action } = request.params as { pid: string; action: string };
    if (action !== "enable" && action !== "disable") {
      throw new HttpContractError(404, "unknown action");
    }
    const current = (await getSettings({ db: deps.db })).plans;
    if (!current.some((p) => p.id === pid)) {
      throw new HttpContractError(404, "unknown plan");
    }
    const newList = current.map((p) =>
      p.id === pid ? { ...p, enabled: action === "enable" } : p,
    );
    const result = await applySettings(
      deps,
      request,
      { plans: newList },
      false,
      `plan-${action}`,
      pid,
    );
    return reply.code(result.accepted ? 202 : 200).send(result);
  });

  // ---- models ----

  adminApp.get("/admin/models", async (request) => {
    auth(request);
    const settings = await getSettings({ db: deps.db });
    const cat = await catalogFor(deps);
    const out = [];
    for (const gid of Object.keys(cat.groups).sort()) {
      const g = cat.groups[gid]!;
      const isAuto = cat.auto_groups.has(gid);
      out.push({
        id: gid,
        name: g.name,
        kind: isAuto ? "chat" : groupKind(g),
        est_unit_cost_usd: unitCost(g, settings, {}),
        input_cost_per_token: g.inputs.length > 0 ? Math.max(...g.inputs) : null,
        output_cost_per_token: g.outputs.length > 0 ? Math.max(...g.outputs) : null,
        output_cost_per_image: g.per_image.length > 0 ? Math.max(...g.per_image) : null,
        members: isAuto
          ? [...new Set(g.underlying.map((u) => publicFor(cat, u) ?? u))].sort()
          : null,
      });
    }
    return { models: out };
  });

  // ---- per-user overrides ----

  /** = POST /admin/set-tier (legacy alias on the same handler). */
  async function adminUserUpdate(request: FastifyRequest, reply: FastifyReply): Promise<unknown> {
    auth(request);
    const body = requireBodyObject(request);
    const rawUid = optStr(body.uid);
    if (rawUid === null || rawUid.trim() === "") {
      throw new HttpContractError(400, "uid required");
    }
    const uid = rawUid.trim();
    const settings = await getSettings({ db: deps.db });

    let plan: PlanData | null = null;
    const tier = optStr(body.tier);
    if (body.tier !== undefined && body.tier !== null && typeof body.tier !== "string") {
      throw new HttpContractError(400, "tier must be a string");
    }
    if (tier !== null && tier !== "") {
      plan = findPlan(settings, tier);
      if (tier !== plan.id && !plan.aliases.includes(tier)) {
        throw new HttpContractError(400, "unknown plan");
      }
    }
    const dailyUsd = numField(body, "daily_usd");
    const monthlyCapUsd = numField(body, "monthly_cap_usd");
    for (const [name, v] of [
      ["daily_usd", dailyUsd],
      ["monthly_cap_usd", monthlyCapUsd],
    ] as const) {
      if (v !== null && (v < 0 || Number.isNaN(v))) {
        throw new HttpContractError(400, `${name} must be >= 0`);
      }
    }
    let poolsOverride: PoolsOverride | null = null;
    if (body.pools !== undefined && body.pools !== null) {
      if (typeof body.pools !== "object" || Array.isArray(body.pools)) {
        throw new HttpContractError(400, "pools must be an object");
      }
      poolsOverride = validatePoolOverride(body.pools as Record<string, unknown>);
    }

    return withBillingAccountWrite(deps, uid, async () => {
      const generation = currentBillingProjectionGeneration();
      if (generation === undefined) throw new StaleBillingAccountWriteError();
      const before = await userState(deps, uid);
      const projection = createProjection({ db: deps.db, redis: deps.redis });

      // Postgres first (authority), then the db2 projection
      if (plan !== null) {
        // M4: an admin tier grant is not a purchase — a stale purchased expiry
        // would silently re-expire the admin's grant on the next resync.
        if (!(await billingUsers.setTierForRefresh(deps.db, uid, plan.id, null, generation))) {
          throw new StaleBillingAccountWriteError();
        }
      }
      const overrideWrite: { dailyUsd?: string | null; monthlyCapUsd?: string | null; pools?: PoolsOverride | null } = {};
      if (boolField(body, "clear_daily_usd", false)) {
        overrideWrite.dailyUsd = null;
      } else if (dailyUsd !== null) {
        overrideWrite.dailyUsd = pyNumStr(dailyUsd);
      }
      if (boolField(body, "clear_monthly_cap_usd", false)) {
        overrideWrite.monthlyCapUsd = null;
      } else if (monthlyCapUsd !== null) {
        overrideWrite.monthlyCapUsd = pyNumStr(monthlyCapUsd);
      }
      if (boolField(body, "clear_pools", false)) {
        overrideWrite.pools = null;
      } else if (poolsOverride !== null && Object.keys(poolsOverride).length > 0) {
        overrideWrite.pools = poolsOverride;
      }
      if (Object.keys(overrideWrite).length > 0) {
        // M2: user_plan_overrides has an FK to users. An override-only update
        // for an unknown uid is a 404 (Python accepted it, but silently
        // dropping a typo'd entitlement is worse than an explicit miss).
        if (plan === null && (await userRow(deps, uid)) === null) {
          throw new HttpContractError(404, "user not found");
        }
        if (!(await billingUsers.saveOverrideForRefresh(deps.db, uid, overrideWrite, generation)) ||
            !(await billingUsers.markProvisionedForRefresh(deps.db, uid, generation))) {
          throw new StaleBillingAccountWriteError();
        }
      }
      try {
        if (plan !== null) {
          await projection.publishUserTier(uid, storedTier(plan), null);
        }
        await projection.publishUserState(uid);
      } catch (err) {
        // I3: the Postgres write already committed. Log the real cause, audit
        // the durable change and answer a sanitized 500 — never the driver text.
        console.log(
          `[mint] user update projection failed after postgres commit: ${errorName(err)}`,
        );
        const durable = await userState(deps, uid);
        await audit(deps, "set-user", {
          target: uid,
          before,
          after: { ...durable, projection_error: "redis projection failed" },
          ip: requestIp(request),
        });
        throw new HttpContractError(
          500,
          "user saved but the redis projection failed; retry or resync",
        );
      }

      let res: ReapplyResult;
      try {
        res = await reapplyUser(deps, uid);
      } catch (error) {
        const after = await userState(deps, uid);
        await audit(deps, "set-user", {
          target: uid,
          before,
          after: { ...after, projection_error: "LiteLLM projection unresolved" },
          ip: requestIp(request),
        });
        console.log(`[mint] user update remote projection unresolved: ${errorName(error)}`);
        throw new HttpContractError(
          503,
          "user saved but the LiteLLM projection is unresolved; retry or resync",
        );
      }
      const after = await userState(deps, uid);
      if (res.errors > 0) {
        await audit(deps, "set-user", {
          target: uid,
          before,
          after: { ...after, projection_error: "LiteLLM projection unresolved" },
          ip: requestIp(request),
        });
        throw new HttpContractError(
          503,
          "user saved but the LiteLLM projection is unresolved; retry or resync",
        );
      }
      await dropUsageCache(deps, [uid]);
      await audit(deps, "set-user", { target: uid, before, after, ip: requestIp(request) });
      return reply.send({ ok: true, user: after, reapplied: res });
    });
  }

  adminApp.post("/admin/user/update", adminUserUpdate);
  adminApp.post("/admin/set-tier", adminUserUpdate);

  // ---- window resets ----

  async function doReset(
    request: FastifyRequest,
    body: Record<string, unknown>,
    action: string,
    resetMonthFreeDefault: boolean,
  ): Promise<{ ok: boolean; accepted: boolean; reset: number; detail: unknown }> {
    const resetMonthFree = boolField(body, "reset_month_free", resetMonthFreeDefault);
    const operationId = optStr(body.operation_id)?.trim() ?? "";
    if (!/^[A-Za-z0-9._:-]{8,128}$/.test(operationId)) {
      throw new HttpContractError(400, "operation_id is required for recoverable window reset");
    }

    // I1: ALL-users is an EXPLICIT request only. A missing/whitespace uid is
    // a client error, never an implicit global reset. `{all:true}` is the
    // documented shape (the console sends it).
    const hasUid = body.uid !== undefined && body.uid !== null;
    const hasAll = body.all !== undefined && body.all !== null;
    if (hasUid && hasAll) {
      throw new HttpContractError(400, "specify either uid or all, not both");
    }
    let uid: string | null = null;
    if (hasUid) {
      if (typeof body.uid !== "string" || body.uid.trim() === "") {
        throw new HttpContractError(400, "uid required");
      }
      uid = body.uid.trim();
    }
    let all = false;
    if (hasAll) {
      if (body.all !== true) {
        throw new HttpContractError(400, "all must be true");
      }
      all = true;
    }
    if (uid === null && !all) {
      throw new HttpContractError(400, "uid required (or {all:true} for every user)");
    }

    let detail: { mode: string; users: number; keys?: number; errors?: number };
    let target: string;
    if (uid !== null) {
      const res = await resetWindowUser(deps, uid, { resetMonthFree, operationId });
      detail = { mode: "sync", users: 1, keys: res.keys, errors: res.errors };
      target = uid;
    } else {
      // ALL users: inline while small, else background with progress
      const uids = await plansRepo.mintUids(deps.db);
      const run = (): Promise<RunTotal> =>
        runOverUsers(deps, RESET_STATUS_KEY, uids, (u) =>
          resetWindowUser(deps, u, { resetMonthFree, operationId }),
        );
      if (uids.length <= deps.env.reapplySyncMax) {
        detail = { mode: "sync", ...(await run()) };
      } else {
        setImmediate(() => {
          run().catch((err: unknown) => {
            console.log(`[mint] background reset: ${errorName(err)}`);
          });
        });
        detail = { mode: "background", users: uids.length };
      }
      target = "ALL";
    }
    await audit(deps, action, {
      target,
      after: { reset_month_free: resetMonthFree },
      ip: requestIp(request),
    });
    if (detail.mode === "sync" && (detail.errors ?? 0) > 0) {
      throw new HttpContractError(503, "window reset saved but the LiteLLM projection is unresolved");
    }
    const accepted = detail.mode === "background";
    return { ok: !accepted, accepted, reset: detail.keys ?? 0, detail };
  }

  adminApp.post("/admin/reset-window", async (request, reply) => {
    auth(request);
    const result = await doReset(request, requireBodyObject(request), "reset-window", false);
    return reply.code(result.accepted ? 202 : 200).send(result);
  });

  /** Legacy name: a window reset that also zeroes the monthly backstop. */
  adminApp.post("/admin/reset-usage", async (request, reply) => {
    auth(request);
    const result = await doReset(request, requireBodyObject(request), "reset-usage", true);
    return reply.code(result.accepted ? 202 : 200).send(result);
  });

  adminApp.get("/admin/reset-status", async (request) => {
    auth(request);
    return await statusJson(RESET_STATUS_KEY);
  });

  // ---- bans ----

  /**
   * The Postgres half of a ban/unban. M3: an UNBAN never inserts a row — a
   * typo'd uid must not become a durable user that later shows up in
   * all-users operations. A ban of an unknown uid does insert one (the
   * durable authority needs a row to carry banned_at).
   */
  async function setBanned(
    uid: string,
    banned: boolean,
    reason: string,
    generation: number,
  ): Promise<void> {
    if (!(await billingUsers.setBannedForRefresh(
      deps.db,
      uid,
      banned,
      reason,
      isoUtc(clockNow(deps)),
      generation,
    ))) {
      throw new StaleBillingAccountWriteError();
    }
  }

  /**
   * I3: projection after the Postgres commit. Returns the failure instead of
   * throwing so the caller can still perform the live-side effect
   * (setKeyBlocked), audit, and then answer a sanitized 500.
   */
  async function projectBan(uid: string, clearBan: boolean): Promise<unknown | null> {
    try {
      await createProjection({ db: deps.db, redis: deps.redis }).publishUserState(uid, {
        clearBan,
      });
      return null;
    } catch (err) {
      console.log(`[mint] ban projection failed after postgres commit: ${errorName(err)}`);
      return err;
    }
  }

  adminApp.post("/admin/ban", async (request, reply) => {
    auth(request);
    const body = requireBodyObject(request);
    const rawUid = optStr(body.uid);
    const ip = optStr(body.ip);
    let before: AdminUserState | null = null;
    let after: AdminUserState | null = null;
    let projectionError: unknown | null = null;
    let remoteError: unknown | null = null;
    if (rawUid !== null && rawUid.trim() !== "") {
      const uid = rawUid.trim();
      await withBillingAccountWrite(deps, uid, async () => {
        const generation = currentBillingProjectionGeneration();
        if (generation === undefined) throw new StaleBillingAccountWriteError();
        before = await userState(deps, uid);
        await setBanned(uid, true, "admin", generation);
        projectionError = await projectBan(uid, false);
        // The live side effect still runs after a Redis failure, but its own
        // unresolved result is never converted into an ok response.
        try {
          await setKeyBlocked(deps, uid, true);
        } catch (error) {
          remoteError = error;
        }
        after = await userState(deps, uid);
      });
    }
    if (ip !== null && ip.trim() !== "") {
      await deps.redis.setex(`ban:ip:${ip.trim()}`, BAN_IP_TTL_S, "admin");
    }
    await audit(deps, "ban", { target: { uid: rawUid, ip }, before, after, ip: requestIp(request) });
    if (remoteError !== null) {
      throw new HttpContractError(503, "ban saved but the key projection is unresolved; retry or resync");
    }
    if (projectionError !== null) {
      throw new HttpContractError(
        500,
        "ban saved but the redis projection failed; retry or resync",
      );
    }
    return reply.send({ ok: true });
  });

  adminApp.post("/admin/unban", async (request, reply) => {
    auth(request);
    const body = requireBodyObject(request);
    const rawUid = optStr(body.uid);
    const ip = optStr(body.ip);
    let before: AdminUserState | null = null;
    let after: AdminUserState | null = null;
    let projectionError: unknown | null = null;
    let remoteError: unknown | null = null;
    if (rawUid !== null && rawUid.trim() !== "") {
      const uid = rawUid.trim();
      await withBillingAccountWrite(deps, uid, async () => {
        const generation = currentBillingProjectionGeneration();
        if (generation === undefined) throw new StaleBillingAccountWriteError();
        before = await userState(deps, uid);
        await setBanned(uid, false, "", generation);
        // clearBan: an explicit admin unban overrides the projection's
        // Redis-only-ban preservation (I2).
        projectionError = await projectBan(uid, true);
        try {
          await setKeyBlocked(deps, uid, false);
        } catch (error) {
          remoteError = error;
        }
        after = await userState(deps, uid);
      });
    }
    if (ip !== null && ip.trim() !== "") {
      await deps.redis.del(`ban:ip:${ip.trim()}`);
    }
    await audit(deps, "unban", { target: { uid: rawUid, ip }, before, after, ip: requestIp(request) });
    if (remoteError !== null) {
      throw new HttpContractError(503, "unban saved but the key projection is unresolved; retry or resync");
    }
    if (projectionError !== null) {
      throw new HttpContractError(
        500,
        "unban saved but the redis projection failed; retry or resync",
      );
    }
    return reply.send({ ok: true });
  });

  // ---- lookup ----

  async function resolveUid(deps: MintDeps, q: string): Promise<string | null> {
    const query = (q ?? "").trim();
    if (query === "") {
      return null;
    }
    let uid: string | null;
    if (query.includes("@")) {
      const rows = (await deps.db.$client`
        SELECT uid FROM users WHERE lower(email) = ${query.toLowerCase()} LIMIT 1`) as Array<{
        uid: string;
      }>;
      uid = rows[0]?.uid ?? null;
    } else {
      uid = query;
    }
    if (uid === null) {
      return null;
    }
    const known =
      (await userRow(deps, uid)) !== null ||
      (await deps.redis.exists(`user:${uid}:tier`)) === 1 ||
      Object.keys(await poolUserKeyIds(deps, uid)).length > 0;
    return known ? uid : null;
  }

  adminApp.get("/admin/user", async (request) => {
    auth(request);
    const query = request.query as Record<string, unknown> | undefined;
    const q = typeof query?.q === "string" ? query.q : "";
    const uid = await resolveUid(deps, q);
    if (uid === null) {
      throw new HttpContractError(404, "user not found");
    }
    const { body, detail, settings: usageSettings } = await computeUsage(deps, uid);
    const settings = await getSettings({ db: deps.db });
    const plan = await planFor(deps, uid, settings);
    const [row, override, banned] = await Promise.all([
      userRow(deps, uid),
      plansRepo.getOverride(deps.db, uid),
      deps.redis.get(`user:${uid}:banned`),
    ]);
    return {
      uid,
      email: row?.email ?? null,
      tier: body.tier,
      plan,
      banned,
      override_daily_usd: override?.dailyUsd ?? null,
      override_monthly_cap_usd: override?.monthlyCapUsd ?? null,
      override_pools: override?.pools ?? null,
      free_daily_usd: await userFreeDaily({ db: deps.db }, uid),
      pools_usd: detail.pools_usd,
      pool_state_usd: detail.pool_state_usd,
      hook_counter_usd: detail.hook_counter_usd,
      slow_mode: detail.slow_mode,
      allowance_usd: body.daily_budget_usd,
      window: body.window,
      window_start: detail.window_start,
      resets_at: body.resets_at,
      today: { ...body.today, spend_usd: detail.spend_usd },
      month_spent_usd: body.month_free_spent_usd,
      month_cap_usd: body.month_free_cap_usd,
      remaining_usd: detail.remaining_usd,
      remaining_fraction: body.remaining_fraction,
      keys: detail.keys,
      app_view: await withAppPlanFields(deps, uid, body, usageSettings, deps.billing),
    };
  });

  // ---- audit / status / sweep / export ----

  adminApp.get("/admin/audit", async (request) => {
    auth(request);
    const query = request.query as Record<string, unknown> | undefined;
    const parsed = Number(query?.limit);
    let limit = Number.isFinite(parsed) ? Math.trunc(parsed) : 100;
    limit = Math.max(1, Math.min(limit, deps.env.auditMax));
    const rows = await deps.redis.lrange(AUDIT_LIST, 0, limit - 1);
    const entries: unknown[] = [];
    for (const row of rows) {
      try {
        entries.push(JSON.parse(row));
      } catch {
        // a corrupt line is skipped, never a 500
      }
    }
    return { entries };
  });

  adminApp.get("/admin/reapply-status", async (request) => {
    auth(request);
    return await statusJson(REAPPLY_STATUS_KEY);
  });

  /** Run the slow-mode sweep now (it also runs in the background). */
  adminApp.post("/admin/sweep", async (request) => {
    auth(request);
    return await sweepSlowMode(deps);
  });

  /** Backup of the entitlements: settings + every known user's state. */
  adminApp.get("/admin/export", async (request) => {
    auth(request);
    const settings = await getSettings({ db: deps.db });
    const users: Record<string, unknown> = {};
    for (const uid of await plansRepo.mintUids(deps.db)) {
      const [state, row] = await Promise.all([userState(deps, uid), userRow(deps, uid)]);
      users[uid] = { ...state, email: row?.email ?? null };
    }
    return { exported_at: isoUtc(clockNow(deps)), settings, users };
  });

  // ---- legacy: set-base-budget ----

  adminApp.post("/admin/set-base-budget", async (request, reply) => {
    auth(request);
    const body = requireBodyObject(request);
    const dailyUsd = numField(body, "daily_usd");
    if (dailyUsd === null || !(dailyUsd >= 0)) {
      throw new HttpContractError(400, "daily_usd must be >= 0");
    }
    const reapply = reapplyFlag(request, body);
    const result = await applySettings(
      deps,
      request,
      { free_daily_usd: dailyUsd },
      reapply,
      "set-base-budget",
    );
    const r = result.reapplied as { keys?: number; users?: number };
    return reply.code(result.accepted ? 202 : 200).send({
      ok: result.ok,
      accepted: result.accepted,
      base_daily_usd: dailyUsd,
      reapplied: r.keys ?? r.users ?? 0,
      detail: r,
    });
  });

  // ---- the console page (no key: it is a client of this API) ----

  function serveConsole(reply: FastifyReply): FastifyReply {
    return reply
      .code(200)
      .headers(CONSOLE_HEADERS)
      .header("content-type", "text/html; charset=utf-8")
      .send(ADMIN_CONSOLE_HTML);
  }

  adminApp.get("/admin", async (_request, reply) => serveConsole(reply));
  adminApp.get("/admin/ui", async (_request, reply) => serveConsole(reply));
}

function tryJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : String(err);
}
