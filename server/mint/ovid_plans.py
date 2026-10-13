"""Ovid plan + pool math, shared by mint and the LiteLLM pools hook.

Pure functions only: callers fetch the raw Redis values (sync in mint, async in
the hook) and pass them in. Every number lives in Redis (``config:limits`` +
``config:base_daily_usd``) and is editable from the mint /admin console; the
constants below are FIRST-RUN SEEDS used only while a setting is unset.

Plans are data: ``settings["plans"]`` is a list the owner can extend, rename,
re-price or disable. Two plan kinds exist:

* ``shared`` – one allowance per window = user's free allowance × ``mult``
  (scaled by window length); frontier models may use at most
  ``frontier_share`` of it.
* ``split``  – an open-source fair-use pool (``oss_usd``) plus a frontier pool
  (``frontier_usd``). Exceeding the oss pool turns on slow mode (never a
  block); exhausting the frontier pool rejects frontier requests.

All USD amounts are per 24h and scale with the plan's window length
(window_hours / 24), so a 30-day window gives a 30× pool.
"""
from __future__ import annotations

import json
import math
import re

LIMITS_HASH = "config:limits"
BASE_BUDGET_KEY = "config:base_daily_usd"
PUBLIC_MAP_KEY = "config:model_public_map"   # underlying model string -> public name
SLOW_HASH = "pools:slow"                      # uid -> slow-mode-until epoch
SLOW_PENDING = "pools:slow_pending"           # uids the hook saw cross the oss pool
AUTO_MODEL = "auto"
CLASSES = ("oss", "frontier")
IMAGE_CALL_TYPES = {"image_generation", "aimage_generation", "image_edit", "aimage_edit",
                    "image_variation", "aimage_variation"}
PLAN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
PLAN_KINDS = ("shared", "split")

# ── first-run seeds (never override a stored value) ──
SEED_OSS_MODELS = ["glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3"]


def seed_plans(paid_window_hours: int = 24) -> list[dict]:
    return [
        {"id": "free", "name": "Free", "price_usd": 0, "enabled": True, "aliases": [],
         "kind": "shared", "window_hours": 24, "mult": 1, "frontier_share": 0.25},
        {"id": "starter", "name": "Starter", "price_usd": 5, "enabled": True, "aliases": ["3x"],
         "kind": "shared", "window_hours": paid_window_hours, "mult": 3, "frontier_share": 0.25},
        {"id": "pro", "name": "Pro", "price_usd": 25, "enabled": True, "aliases": ["7x"],
         "kind": "split", "window_hours": paid_window_hours, "oss_usd": 2.0, "frontier_usd": 1.5},
        {"id": "max", "name": "Max", "price_usd": 60, "enabled": True, "aliases": ["15x"],
         "kind": "split", "window_hours": paid_window_hours, "oss_usd": 3.0, "frontier_usd": 3.5},
    ]


# name -> (type, seed, lo, hi). Seeds for env-backed values come from `seeds`.
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
    "hard_ceiling_mult": (float, 3.0, 1, 1000),
}
STRINGS = {"auto_oss_group": ""}
PLAN_NUMBERS = {  # field -> (lo, hi, kinds)
    "price_usd": (0, 100000, PLAN_KINDS),
    "window_hours": (1, 24 * 366, PLAN_KINDS),
    "mult": (0, 10000, ("shared",)),
    "frontier_share": (0, 1, ("shared",)),
    "oss_usd": (0, 100000, ("split",)),
    "frontier_usd": (0, 100000, ("split",)),
}
POOL_OVERRIDE_FIELDS = ("mult", "frontier_share", "oss_usd", "frontier_usd", "window_hours")


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
    unset values fall back to the seeds."""
    h = h or {}
    seeds = seeds or {}
    s = {"free_daily_usd": _num(base_raw, seeds.get("free_daily_usd", 0.15))}
    for name, (typ, seed, _lo, _hi) in SCALARS.items():
        v = _num(h.get(name), seeds.get(name, seed))
        s[name] = int(v) if typ is int else float(v)
    for name, seed in STRINGS.items():
        s[name] = h.get(name, seeds.get(name, seed)) or ""
    s["oss_models"] = _json(h.get("oss_models"), list(seeds.get("oss_models", SEED_OSS_MODELS)))
    s["plans"] = _json(h.get("plans"), seeds.get("plans") or seed_plans())
    return s


def serialize_settings(s: dict) -> tuple[str, dict]:
    """(base_daily value, hash fields) for storage."""
    fields = {k: str(s[k]) for k in SCALARS}
    fields.update({k: s[k] for k in STRINGS})
    fields["oss_models"] = json.dumps(s["oss_models"])
    fields["plans"] = json.dumps(s["plans"], sort_keys=True)
    return str(s["free_daily_usd"]), fields


def _bounded(name, v, lo, hi):
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
    kind = p.get("kind", "shared")
    if kind not in PLAN_KINDS:
        raise ValueError("plan kind must be 'shared' or 'split'")
    out = {"id": pid, "name": str(p.get("name") or pid)[:64], "kind": kind,
           "enabled": bool(p.get("enabled", True))}
    aliases = p.get("aliases") or []
    if not isinstance(aliases, list) or not all(isinstance(a, str) and PLAN_ID_RE.match(a) for a in aliases):
        raise ValueError(f"plan {pid}: aliases must be a list of ids")
    out["aliases"] = aliases
    for f, (lo, hi, kinds) in PLAN_NUMBERS.items():
        if kind not in kinds:
            continue
        default = {"price_usd": 0, "window_hours": 24, "mult": 1, "frontier_share": 0.25,
                   "oss_usd": 0, "frontier_usd": 0}[f]
        out[f] = _bounded(f"{pid}.{f}", p.get(f, default), lo, hi)
    out["window_hours"] = int(out["window_hours"])
    return out


def validate_settings(s: dict) -> dict:
    out = dict(s)
    out["free_daily_usd"] = _bounded("free_daily_usd", s["free_daily_usd"], 0, 100000)
    for name, (typ, _seed, lo, hi) in SCALARS.items():
        v = _bounded(name, s[name], lo, hi)
        out[name] = int(v) if typ is int else v
    for name in STRINGS:
        out[name] = str(s.get(name) or "")[:128]
    oss = s.get("oss_models")
    if not isinstance(oss, list) or not all(isinstance(m, str) and m for m in oss):
        raise ValueError("oss_models must be a list of model names")
    out["oss_models"] = sorted(set(oss))
    plans = [validate_plan(p) for p in (s.get("plans") or [])]
    ids = [p["id"] for p in plans]
    if "free" not in ids:
        raise ValueError("the 'free' plan is required")
    names = ids + [a for p in plans for a in p["aliases"]]
    if len(names) != len(set(names)):
        raise ValueError("plan ids and aliases must be unique")
    for p in plans:
        if p["id"] == "free" and (not p["enabled"] or p["kind"] != "shared"):
            raise ValueError("the 'free' plan must stay enabled and 'shared'")
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
    """Caps (USD per window) for one user on one plan; `override` holds the
    admin's per-user custom pool fields."""
    p = dict(plan)
    for f in POOL_OVERRIDE_FIELDS:
        if override and override.get(f) is not None:
            p[f] = override[f]
    hours = int(p.get("window_hours") or 24)
    k = hours / 24.0
    out = {"plan_id": plan["id"], "kind": p["kind"], "window_hours": hours,
           "all": None, "oss": None, "frontier": None}
    if p["kind"] == "shared":
        total = float(free_daily) * float(p.get("mult", 1)) * k
        out["all"] = round(total, 6)
        out["frontier"] = round(total * float(p.get("frontier_share", 0.25)), 6)
    else:
        out["oss"] = round(float(p.get("oss_usd", 0)) * k, 6)
        out["frontier"] = round(float(p.get("frontier_usd", 0)) * k, 6)
    return out


def key_budget(pools: dict, s: dict) -> float:
    """LiteLLM key max_budget per window (a backstop; pools are enforced by the
    hook). Split plans keep running in slow mode past the oss pool, so their
    ceiling is hard_ceiling_mult × oss + frontier."""
    if pools["kind"] == "shared":
        return pools["all"]
    return round(pools["oss"] * s["hard_ceiling_mult"] + pools["frontier"], 6)


# ── model classes ──
def model_class(name: str, s: dict) -> str:
    if name == AUTO_MODEL or (s.get("auto_oss_group") and name == s["auto_oss_group"]):
        return "auto"
    return "oss" if name in s["oss_models"] else "frontier"


def public_name(under: str, public_map: dict) -> str | None:
    if not under:
        return None
    return public_map.get(under) or public_map.get(under.split("/", 1)[-1])


def served_class(model_group: str, served_model: str, call_type: str,
                 public_map: dict, s: dict) -> tuple[str, str]:
    """(class, public model) of a finished request. Images are frontier; auto
    is attributed to the member that served it (frontier if unknown)."""
    if call_type in IMAGE_CALL_TYPES:
        return "frontier", (model_group or public_name(served_model, public_map) or served_model)
    if model_group and model_class(model_group, s) != "auto":
        return model_class(model_group, s), model_group
    pub = public_name(served_model, public_map)
    if pub and model_class(pub, s) != "auto":
        return model_class(pub, s), pub
    return "frontier", (pub or model_group or served_model or AUTO_MODEL)


def pool_state(pools: dict, spend: dict, all_cap_left: float | None = None) -> dict:
    """Remaining USD per pool. `all_cap_left` lets the caller apply an extra
    ceiling (the free monthly backstop) to the shared pool."""
    so, sf = float(spend.get("oss", 0)), float(spend.get("frontier", 0))
    if pools["kind"] == "shared":
        rem_all = max(0.0, pools["all"] - so - sf)
        if all_cap_left is not None:
            rem_all = min(rem_all, max(0.0, all_cap_left))
        rem_f = min(max(0.0, pools["frontier"] - sf), rem_all)
        return {"all": {"cap": pools["all"], "spent": so + sf, "remaining": rem_all},
                "frontier": {"cap": pools["frontier"], "spent": sf, "remaining": rem_f},
                "oss": None, "slow_mode": False}
    rem_o = max(0.0, pools["oss"] - so)
    rem_f = max(0.0, pools["frontier"] - sf)
    return {"all": None,
            "oss": {"cap": pools["oss"], "spent": so, "remaining": rem_o},
            "frontier": {"cap": pools["frontier"], "spent": sf, "remaining": rem_f},
            "slow_mode": so >= pools["oss"]}


def decide(s: dict, pools: dict, spend: dict, requested_model: str, call_type: str) -> dict:
    """Pre-call decision for the hook: allow, reject with a code, or route
    auto to the oss-only group."""
    cls = "frontier" if call_type in IMAGE_CALL_TYPES else model_class(requested_model, s)
    st = pool_state(pools, spend)
    if pools["kind"] == "shared":
        if st["all"]["remaining"] <= 0:
            return {"action": "reject", "code": "daily_limit_reached"}
        if cls == "frontier" and st["frontier"]["remaining"] <= 0:
            return {"action": "reject", "code": "frontier_limit_reached"}
        return {"action": "allow"}
    if cls == "frontier" and st["frontier"]["remaining"] <= 0:
        return {"action": "reject", "code": "frontier_limit_reached"}
    if requested_model == AUTO_MODEL and s.get("auto_oss_group"):
        return {"action": "allow", "model": s["auto_oss_group"]}
    return {"action": "allow"}


def pool_keys(uid: str) -> dict:
    return {"start": f"pool:{uid}:start", "oss": f"pool:{uid}:spend:oss",
            "frontier": f"pool:{uid}:spend:frontier"}
