"""Ovid plan + allowance math, shared by mint and the LiteLLM pools hook.

Pure functions only: callers fetch the raw Redis values (sync in mint, async in
the hook) and pass them in. Every number lives in Redis (``config:limits`` +
``config:base_daily_usd``) and is editable from the mint /admin console; the
constants below are FIRST-RUN SEEDS used only while a setting is unset.

One idea only: every plan is ONE allowance per window, consumed at each
model's LiteLLM price (set by the owner in LiteLLM). There are no model
classes. A plan's allowance = the user's free allowance × the plan's ``mult``,
scaled by window length (amounts are per 24h; window_hours / 24). When it is
used up the request is rejected with ``daily_limit_reached`` — or, for plans
with ``slow_mode`` on, served with lower rate limits until the window resets.

Plans are data: ``settings["plans"]`` is a list the owner can extend, rename,
re-price, disable or edit.

Hidden auto routing: a plan with ``auto_oss`` on has its ``auto`` requests
rewritten by the hook to a weighted-random member of ``auto_oss_members``
(existing LiteLLM model names) with the other members as fallbacks. The app
never sees this: usage is reported as "auto", attributed to the served model.
"""
from __future__ import annotations

import datetime
import json
import math
import os
import random
import re
from dataclasses import dataclass

LIMITS_HASH = "config:limits"
BASE_BUDGET_KEY = "config:base_daily_usd"
SLOW_HASH = "pools:slow"                      # uid -> slow-mode-until epoch
SLOW_PENDING = "pools:slow_pending"           # uids the hook saw exhaust a slow-mode plan
AUTO_MODEL = "auto"
MODEL_GROUPS_KEY = "config:model_groups"     # JSON list of LiteLLM model names (published by mint)
SEED_AUTO_OSS_MEMBERS = [{"model": "glm-5.3-flash", "weight": 1.0},
                         {"model": "deepseek-v4.1-flash", "weight": 1.0},
                         {"model": "minimax-m3", "weight": 1.0}]
PLAN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")

# ── Free-plan token ceilings (product spec §11 / decision D1) ──
#
# Per user, rolling: 50M tokens in any trailing 24h and 1.5B in any trailing
# 30 days. These are HARD ceilings on top of the USD allowance; a paid plan is
# not subject to them (it keeps the existing free-allowance × mult behaviour).
# No shared pool and no borrowing: every key is namespaced by uid, and the two
# windows are evaluated independently (a user may not spend monthly headroom
# because the day is fresh, or vice versa).
#
# Storage is bucketed so one Redis hash per user per window is enough: the
# field is the bucket start (epoch seconds), the value is the token count. The
# daily window uses 5-minute buckets and the monthly window 1-hour buckets; a
# bucket that overlaps the window is counted in full, which makes enforcement
# conservative (it can never under-count a live token) and makes the computed
# reset time at most one bucket late.
FREE_DAILY_TOKENS = 50_000_000
FREE_MONTHLY_TOKENS = 1_500_000_000
TOKEN_DAY_WINDOW_S = 24 * 3600
TOKEN_MONTH_WINDOW_S = 30 * 24 * 3600
TOKEN_DAY_BUCKET_S = 5 * 60
TOKEN_MONTH_BUCKET_S = 3600

# M1 monitoring gate: per-user UTC-day spend alert queue + the env kill switch.
SPEND_ALERT_PENDING = "alerts:pending:user_spend"
SPEND_ALERT_QUEUED_PREFIX = "alert:user_spend:queued"
SPEND_ALERT_SENT_PREFIX = "alert:user_spend:sent"
KILL_SWITCH_ENV = "OVID_PAID_MODELS_KILL_SWITCH"
KILL_SWITCH_KEY = "config:kill_switch"   # runtime flip from /admin (env wins)
PAID_MODELS_DISABLED = "paid_models_disabled"


def seed_plans(paid_window_hours: int = 24) -> list[dict]:
    """First-run plans. Multipliers put the paid allowances near the earlier
    totals at a 0.15 base: pro ≈ 3.45/day, max ≈ 6.45/day."""
    return [
        {"id": "free", "name": "Free", "price_usd": 0, "enabled": True, "aliases": [],
         "window_hours": 24, "mult": 1, "slow_mode": False, "auto_oss": False},
        {"id": "starter", "name": "Go", "price_usd": 5, "enabled": True, "aliases": ["3x"],
         "window_hours": paid_window_hours, "mult": 3, "slow_mode": False, "auto_oss": False},
        {"id": "pro", "name": "Plus", "price_usd": 18, "enabled": True, "aliases": ["7x"],
         "window_hours": paid_window_hours, "mult": 23, "slow_mode": False, "auto_oss": True},
        {"id": "max", "name": "Pro", "price_usd": 99, "enabled": True, "aliases": ["15x"],
         "window_hours": paid_window_hours, "mult": 43, "slow_mode": False, "auto_oss": True},
    ]


# name -> (type, seed, lo, hi). Env-backed seeds come from `seeds`.
SCALARS = {
    "free_monthly_cap_usd": (float, 10.0, 0, 100000),
    "est_input_tokens": (int, 2000, 1, 10_000_000),
    "est_output_tokens": (int, 600, 1, 10_000_000),
    "est_image_tokens": (int, 1500, 1, 10_000_000),
    "slow_rpm": (int, 20, 1, 1_000_000),
    "slow_tpm": (int, 200_000, 1, 1_000_000_000),
    "slow_parallel": (int, 2, 1, 10_000),
    "normal_rpm": (int, 240, 1, 1_000_000),
    "normal_tpm": (int, 4_000_000, 1, 1_000_000_000),
    "normal_parallel": (int, 16, 1, 10_000),
    "hard_ceiling_mult": (float, 3.0, 1, 1000),   # key ceiling for slow-mode plans
    "user_daily_spend_alert_usd": (float, 0.50, 0, 100000),  # M1 per-user alert
}
PLAN_NUMBERS = {  # field -> (lo, hi, default)
    "price_usd": (0, 100000, 0),
    "window_hours": (1, 24 * 366, 24),
    "mult": (0, 100000, 1),
}
OVERRIDE_FIELDS = ("mult", "window_hours", "slow_mode", "auto_oss")
BOOL_FIELDS = ("slow_mode", "auto_oss")


def _num(v, default):
    try:
        f = float(v)
        return default if math.isnan(f) else f
    except (TypeError, ValueError):
        return default


def _json(v, default):
    if v in (None, ""):
        return default
    try:
        return json.loads(v)
    except (TypeError, ValueError):
        return default


def parse_settings(h: dict | None, base_raw, seeds: dict | None = None) -> dict:
    """Settings from the raw ``config:limits`` hash + ``config:base_daily_usd``;
    unset values fall back to the seeds. Unknown stored fields are ignored."""
    h = h or {}
    seeds = seeds or {}
    s = {"free_daily_usd": _num(base_raw, seeds.get("free_daily_usd", 0.15))}
    for name, (typ, seed, _lo, _hi) in SCALARS.items():
        v = _num(h.get(name), seeds.get(name, seed))
        s[name] = int(v) if typ is int else float(v)
    raw_members = h.get("auto_oss_members")
    try:
        s["auto_oss_members"] = validate_members(
            seeds.get("auto_oss_members", SEED_AUTO_OSS_MEMBERS) if raw_members is None else json.loads(raw_members))
    except (TypeError, ValueError):
        s["auto_oss_members"] = []   # stored but invalid → plain auto
    raw_plans = _json(h.get("plans"), seeds.get("plans") or seed_plans())
    try:
        s["plans"] = [validate_plan(p) for p in raw_plans]
    except ValueError:
        s["plans"] = seed_plans()
    return s


def serialize_settings(s: dict) -> tuple[str, dict]:
    """(base_daily value, hash fields) for storage."""
    fields = {k: str(s[k]) for k in SCALARS}
    fields["plans"] = json.dumps(s["plans"], sort_keys=True)
    fields["auto_oss_members"] = json.dumps(s["auto_oss_members"])
    return str(s["free_daily_usd"]), fields


def _bounded(name, v, lo, hi):
    if isinstance(v, bool):
        raise ValueError(f"{name} must be a number")
    try:
        f = float(v)
    except (TypeError, ValueError):
        raise ValueError(f"{name} must be a number")
    if math.isnan(f) or not lo <= f <= hi:
        raise ValueError(f"{name} must be between {lo} and {hi}")
    return f


def validate_plan(p: dict) -> dict:
    if not isinstance(p, dict):
        raise ValueError("plan must be an object")
    pid = str(p.get("id") or "")
    if not PLAN_ID_RE.match(pid):
        raise ValueError("plan id must be 1-32 chars of a-z 0-9 _ -")
    aliases = p.get("aliases") or []
    if not isinstance(aliases, list) or not all(isinstance(a, str) and PLAN_ID_RE.match(a) for a in aliases):
        raise ValueError(f"plan {pid}: aliases must be a list of ids")
    out = {"id": pid, "name": str(p.get("name") or pid)[:64], "enabled": bool(p.get("enabled", True)),
           "aliases": aliases, "slow_mode": bool(p.get("slow_mode", False)),
           "auto_oss": bool(p.get("auto_oss", False))}
    for f, (lo, hi, default) in PLAN_NUMBERS.items():
        out[f] = _bounded(f"{pid}.{f}", p.get(f, default), lo, hi)
    out["window_hours"] = int(out["window_hours"])
    return out


def validate_members(members) -> list[dict]:
    """auto_oss_members: model names, or {"model", "weight"} objects."""
    if not isinstance(members, list):
        raise ValueError("auto_oss_members must be a list")
    out, seen = [], set()
    for m in members:
        if isinstance(m, str):
            m = {"model": m, "weight": 1.0}
        if not isinstance(m, dict) or not isinstance(m.get("model"), str) or not m["model"].strip():
            raise ValueError("each auto_oss_members entry needs a model name")
        name = m["model"].strip()
        if name == AUTO_MODEL:
            raise ValueError("auto_oss_members cannot contain 'auto'")
        if name in seen:
            raise ValueError(f"duplicate auto_oss_members entry {name!r}")
        seen.add(name)
        out.append({"model": name, "weight": _bounded(f"{name}.weight", m.get("weight", 1.0), 0.0001, 1e6)})
    return out


def pick_auto_member(members: list[dict], known: set | None = None, rng=random) -> tuple[str, list[str]] | None:
    """Weighted-random member + the others (by weight, descending) as
    fallbacks. Members missing from `known` (LiteLLM model names) are skipped;
    None means use plain auto."""
    usable = [m for m in members if known is None or m["model"] in known]
    if not usable:
        return None
    pick = rng.choices(usable, weights=[m["weight"] for m in usable], k=1)[0]["model"]
    rest = [m["model"] for m in sorted(usable, key=lambda m: -m["weight"]) if m["model"] != pick]
    return pick, rest


def validate_settings(s: dict) -> dict:
    out = {"free_daily_usd": _bounded("free_daily_usd", s["free_daily_usd"], 0, 100000)}
    out["auto_oss_members"] = validate_members(s.get("auto_oss_members", []))
    for name, (typ, seed, lo, hi) in SCALARS.items():
        # Missing fields fall back to their seed so callers that build a
        # partial settings dict (contract tests, first-run seeds) stay valid.
        v = _bounded(name, s.get(name, seed), lo, hi)
        out[name] = int(v) if typ is int else v
    plans = [validate_plan(p) for p in (s.get("plans") or [])]
    ids = [p["id"] for p in plans]
    if "free" not in ids:
        raise ValueError("the 'free' plan is required")
    names = ids + [a for p in plans for a in p["aliases"]]
    if len(names) != len(set(names)):
        raise ValueError("plan ids and aliases must be unique")
    if not next(p for p in plans if p["id"] == "free")["enabled"]:
        raise ValueError("the 'free' plan must stay enabled")
    out["plans"] = plans
    return out


# ── plans ──
def find_plan(s: dict, tier) -> dict:
    """Plan for a stored tier value (id or alias, e.g. legacy 3x/7x/15x).
    Unknown values are the free plan. Disabled plans keep applying to users
    already on them (disable = stop selling)."""
    tier = (tier or "").strip()
    free = None
    for p in s["plans"]:
        if p["id"] == "free":
            free = p
        if tier and (tier == p["id"] or tier in p.get("aliases", [])):
            return p
    return free or seed_plans()[0]


def stored_tier(plan: dict) -> str:
    """Value written to user:{uid}:tier. The first alias keeps billing (which
    knows 3x/7x/15x) compatible."""
    return plan["aliases"][0] if plan.get("aliases") else plan["id"]


def window_str(hours: int) -> str:
    hours = int(hours)
    return f"{hours // 24}d" if hours % 24 == 0 and hours >= 48 else f"{hours}h"


def user_pools(s: dict, plan: dict, free_daily: float, override: dict | None = None) -> dict:
    """The user's allowance (USD per window). `override` holds the admin's
    per-user custom plan fields (mult, window_hours, slow_mode)."""
    p = dict(plan)
    for f in OVERRIDE_FIELDS:
        if override and override.get(f) is not None:
            p[f] = override[f]
    hours = int(p.get("window_hours") or 24)
    total = float(free_daily) * float(p.get("mult", 1)) * hours / 24.0
    return {"plan_id": plan["id"], "window_hours": hours, "all": round(total, 6),
            "slow_mode": bool(p.get("slow_mode")), "auto_oss": bool(p.get("auto_oss"))}


def key_budget(pools: dict, s: dict) -> float:
    """LiteLLM key max_budget per window (a backstop; the hook enforces the
    allowance per user). Slow-mode plans keep running past the allowance, so
    their ceiling is hard_ceiling_mult × allowance."""
    if pools["slow_mode"]:
        return round(pools["all"] * s["hard_ceiling_mult"], 6)
    return pools["all"]


def pool_state(pools: dict, spent: float, cap_left: float | None = None) -> dict:
    """Remaining USD. `cap_left` lets the caller apply an extra ceiling (the
    free monthly backstop)."""
    rem = max(0.0, pools["all"] - float(spent))
    if cap_left is not None:
        rem = min(rem, max(0.0, cap_left))
    return {"all": {"cap": pools["all"], "spent": float(spent), "remaining": rem},
            "slow_mode": bool(pools["slow_mode"] and rem <= 0)}


def decide(pools: dict, spent: float) -> dict:
    """Pre-call decision for the hook."""
    if pools["all"] - float(spent) > 0 or pools["slow_mode"]:
        return {"action": "allow"}
    return {"action": "reject", "code": "daily_limit_reached"}


# ── Free-plan token windows (rolling, per user) ──
def token_keys(uid: str) -> dict:
    """Redis hashes holding the user's bucketed token counts (one per window)."""
    return {"day": f"tokens:{uid}:day", "month": f"tokens:{uid}:month"}


def token_bucket(ts: float, size: int) -> int:
    """Start (epoch seconds) of the bucket containing `ts`."""
    return int(float(ts) // size) * size


def _bucket_rows(buckets: dict | None) -> list[tuple[int, int]]:
    rows = []
    for field, value in (buckets or {}).items():
        try:
            start, n = int(float(field)), int(float(value))
        except (TypeError, ValueError):
            continue
        if n > 0:
            rows.append((start, n))
    rows.sort()
    return rows


def window_sum(buckets: dict | None, now: float, window_s: int, bucket_s: int) -> int:
    """Tokens in the trailing window. A bucket that overlaps the window is
    counted in full (conservative: never under-counts a live token)."""
    cutoff = float(now) - window_s
    return sum(n for start, n in _bucket_rows(buckets) if start + bucket_s > cutoff)


def window_retry_at(buckets: dict | None, now: float, window_s: int, bucket_s: int,
                    excess: int) -> float:
    """Epoch when `excess` tokens have aged out of the window.

    Conservative: waits for the whole bucket that carries the excess to leave
    the window, so the returned time is never earlier than the true boundary.
    """
    cutoff = float(now) - window_s
    acc = 0
    for start, n in _bucket_rows(buckets):
        if start + bucket_s <= cutoff:
            continue
        acc += n
        if acc >= max(1, excess):
            return float(start + bucket_s + window_s)
    return float(now) + window_s


def iso_utc(ts: float) -> str:
    return (datetime.datetime.fromtimestamp(float(ts), datetime.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"))


def retry_after_seconds(retry_at: str | None, now: float) -> int:
    if not retry_at:
        return 0
    try:
        at = datetime.datetime.fromisoformat(retry_at.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return 0
    return max(0, int(at - float(now)))


@dataclass(frozen=True)
class TokenDecision:
    """The admission decision for one request, taken BEFORE any model call.

    `allow`     — whether the request may proceed.
    `reason`    — stable machine reason (`daily_token_cap`, `monthly_token_cap`,
                  `paid_models_disabled`) or None.
    `retry_at`  — ISO-8601 UTC instant when the cap clears, or None.
    `remaining` — tokens left per window (`daily`/`monthly`), None for paid.
    `code`      — wire code for the 429/503 body (`free_daily_cap`, ...).
    `status`    — HTTP status the caller should return.
    """
    allow: bool
    reason: str | None
    retry_at: str | None
    remaining: dict
    code: str | None = None
    status: int = 200

    def as_dict(self) -> dict:
        return {"allow": self.allow, "reason": self.reason, "retry_at": self.retry_at,
                "remaining": dict(self.remaining), "code": self.code, "status": self.status}


def paid_models_disabled() -> TokenDecision:
    """M1 kill switch: deny every model call (all upstream models are paid)."""
    return TokenDecision(False, "paid_models_disabled", None,
                         {"daily": None, "monthly": None},
                         PAID_MODELS_DISABLED, 503)


def truthy(value) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def env_kill_switch_active() -> bool:
    """The env flag is the hard override and needs no Redis."""
    return truthy(os.environ.get(KILL_SWITCH_ENV, "false"))


def kill_switch_active(runtime=None) -> bool:
    """Env flag OR the runtime flag read from Redis.

    Callers should pass the runtime value they read from
    ``KILL_SWITCH_KEY``. The env flag always wins: turning the runtime flag
    off cannot re-enable models while the env flag is set.
    """
    return env_kill_switch_active() or truthy(runtime)


def decide_tokens(plan_id: str, day_buckets: dict | None, month_buckets: dict | None,
                  now: float, daily_cap: int = FREE_DAILY_TOKENS,
                  monthly_cap: int = FREE_MONTHLY_TOKENS) -> TokenDecision:
    """Free-plan token ceiling decision. Paid plans are never token-capped.

    The cap is inclusive: exactly `cap` tokens used means the next request is
    denied, because the cap is the maximum allowance, not one past it.
    """
    if plan_id != "free":
        return TokenDecision(True, None, None, {"daily": None, "monthly": None}, None, 200)
    day = window_sum(day_buckets, now, TOKEN_DAY_WINDOW_S, TOKEN_DAY_BUCKET_S)
    month = window_sum(month_buckets, now, TOKEN_MONTH_WINDOW_S, TOKEN_MONTH_BUCKET_S)
    remaining = {"daily": max(0, int(daily_cap) - day),
                 "monthly": max(0, int(monthly_cap) - month)}
    if day >= daily_cap:
        retry = window_retry_at(day_buckets, now, TOKEN_DAY_WINDOW_S,
                                TOKEN_DAY_BUCKET_S, day - daily_cap + 1)
        return TokenDecision(False, "daily_token_cap", iso_utc(retry), remaining,
                             "free_daily_cap", 429)
    if month >= monthly_cap:
        retry = window_retry_at(month_buckets, now, TOKEN_MONTH_WINDOW_S,
                                TOKEN_MONTH_BUCKET_S, month - monthly_cap + 1)
        return TokenDecision(False, "monthly_token_cap", iso_utc(retry), remaining,
                             "free_monthly_cap", 429)
    return TokenDecision(True, None, None, remaining, None, 200)


def decide_request(plan_id: str, day_buckets: dict | None, month_buckets: dict | None,
                   now: float, kill_switch: bool = False) -> TokenDecision:
    """Kill switch first, then the free-plan token ceilings."""
    if kill_switch:
        return paid_models_disabled()
    return decide_tokens(plan_id, day_buckets, month_buckets, now)


def spend_alert_queued_key(uid: str, day: str) -> str:
    return f"{SPEND_ALERT_QUEUED_PREFIX}:{uid}:{day}"


def spend_alert_sent_key(uid: str, day: str) -> str:
    return f"{SPEND_ALERT_SENT_PREFIX}:{uid}:{day}"


def pool_keys(uid: str) -> dict:
    return {"start": f"pool:{uid}:start", "spend": f"pool:{uid}:spend",
            "auto": f"pool:{uid}:auto"}   # hash: served model -> requests rewritten from auto
