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

import json
import math
import random
import re

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


def seed_plans(paid_window_hours: int = 24) -> list[dict]:
    """First-run plans. Multipliers put the paid allowances near the earlier
    totals at a 0.15 base: pro ≈ 3.45/day, max ≈ 6.45/day."""
    return [
        {"id": "free", "name": "Free", "price_usd": 0, "enabled": True, "aliases": [],
         "window_hours": 24, "mult": 1, "slow_mode": False, "auto_oss": False},
        {"id": "starter", "name": "Starter", "price_usd": 5, "enabled": True, "aliases": ["3x"],
         "window_hours": paid_window_hours, "mult": 3, "slow_mode": False, "auto_oss": False},
        {"id": "pro", "name": "Pro", "price_usd": 25, "enabled": True, "aliases": ["7x"],
         "window_hours": paid_window_hours, "mult": 23, "slow_mode": False, "auto_oss": True},
        {"id": "max", "name": "Max", "price_usd": 60, "enabled": True, "aliases": ["15x"],
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
    for name, (typ, _seed, lo, hi) in SCALARS.items():
        v = _bounded(name, s[name], lo, hi)
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


def pool_keys(uid: str) -> dict:
    return {"start": f"pool:{uid}:start", "spend": f"pool:{uid}:spend",
            "auto": f"pool:{uid}:auto"}   # hash: served model -> requests rewritten from auto
