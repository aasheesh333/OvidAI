"""LiteLLM pools hook: one allowance per plan, daily_limit_reached, optional
slow mode, hidden auto routing to auto_oss_members, fail-open, live settings."""
import asyncio
import json
import random
import sys
import types

import pytest

from conftest import MINT_DIR, AsyncRedis, MemoryRedis

sys.path.insert(0, str(MINT_DIR / "litellm_hook"))
sys.path.insert(0, str(MINT_DIR))
import ovid_plans as plans  # noqa: E402
import ovid_pools  # noqa: E402

NOW = 1_800_000_000.0
GROUPS = ["auto", "glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3", "gemini-3.8-flash", "ovid-image"]


class Clock:
    def __init__(self):
        self.t = NOW

    def __call__(self):
        return self.t


def make_hook(r, clock=None, seed=1):
    return ovid_pools.OvidPools(redis_client=AsyncRedis(r), clock=clock or Clock(), rng=random.Random(seed))


@pytest.fixture
def hook():
    r = MemoryRedis()
    s = plans.parse_settings({}, "1.0")  # free allowance $1/24h
    base, fields = plans.serialize_settings(s)
    r.set(plans.BASE_BUDGET_KEY, base)
    r.hset(plans.LIMITS_HASH, mapping=fields)
    r.set(plans.MODEL_GROUPS_KEY, json.dumps(GROUPS))
    clock = Clock()
    return make_hook(r, clock), r, clock


def run(coro):
    return asyncio.run(coro)


def key(uid):
    return types.SimpleNamespace(user_id=uid)


def pre(h, uid, model, call_type="acompletion", data=None):
    return run(h.async_pre_call_hook(key(uid), None, {"model": model, **(data or {})}, call_type))


def success(h, uid, group, cost, call_type="acompletion", auto=False):
    kwargs = {"standard_logging_object": {"metadata": {"user_api_key_user_id": uid},
                                          "response_cost": cost, "model_group": group,
                                          "model": f"prov/{group}", "call_type": call_type},
              "litellm_params": {"metadata": {"ovid_auto": True} if auto else {}}}
    run(h.async_log_success_event(kwargs, None, None, None))


def rejected(h, uid, model, call_type="acompletion"):
    with pytest.raises(ovid_pools.ProxyException) as e:
        pre(h, uid, model, call_type)
    return e.value


def set_plan(r, pid, **fields):
    s = plans.parse_settings(r.hgetall(plans.LIMITS_HASH), r.get(plans.BASE_BUDGET_KEY))
    s["plans"] = [dict(p, **fields) if p["id"] == pid else p for p in s["plans"]]
    r.hset(plans.LIMITS_HASH, "plans", json.dumps(s["plans"]))


def test_allowance_consumed_at_any_model_then_daily_limit(hook):
    h, r, clock = hook
    assert pre(h, "u", "gemini-3.8-flash")["model"] == "gemini-3.8-flash"
    success(h, "u", "gemini-3.8-flash", 0.6)
    success(h, "u", "glm-5.3-flash", 0.4)
    err = rejected(h, "u", "glm-5.3-flash")
    assert err.type == "daily_limit_reached" and err.code == "429"
    assert err.headers["x-ovid-resets-at"] == ovid_pools._iso(NOW + 86400)
    assert err.provider_specific_fields == {"ovid_error": "daily_limit_reached", "resets_at": ovid_pools._iso(NOW + 86400)}
    assert rejected(h, "u", "auto").type == "daily_limit_reached"
    assert rejected(h, "u", "ovid-image", "aimage_generation").type == "daily_limit_reached"
    assert float(r.get("pool:u:spend")) == pytest.approx(1.0)


@pytest.mark.parametrize("tier,mult", [("3x", 1.5), ("7x", 5), ("15x", 20)])
def test_paid_plans_scale_the_free_allowance(hook, tier, mult):
    h, r, _ = hook
    r.set("user:p:tier", tier)
    success(h, "p", "glm-5.3-flash", mult - 0.01)
    assert pre(h, "p", "glm-5.3-flash")
    success(h, "p", "glm-5.3-flash", 0.02)
    assert rejected(h, "p", "glm-5.3-flash").type == "daily_limit_reached"


def test_slow_mode_plan_never_blocks_and_flags_mint(hook):
    h, r, _ = hook
    set_plan(r, "starter", slow_mode=True)
    r.set("user:s:tier", "starter")
    # This fixture's free daily base is 1.0, so Go's allowance is 1.0 x 1.5 =
    # 1.5 for a 24 h window: stay under it, then cross it.
    success(h, "s", "glm-5.3-flash", 1.4)
    assert not r.sismember(plans.SLOW_PENDING, "s")
    success(h, "s", "glm-5.3-flash", 0.2)
    assert r.sismember(plans.SLOW_PENDING, "s")
    assert pre(h, "s", "gemini-3.8-flash")["model"] == "gemini-3.8-flash"


@pytest.mark.parametrize("tier,rewritten", [("free", False), ("3x", False), ("7x", True), ("15x", True)])
def test_auto_rewrite_per_plan(hook, tier, rewritten):
    h, r, _ = hook
    if tier != "free":
        r.set("user:u:tier", tier)
    data = pre(h, "u", "auto", data={"metadata": {"user_api_key": "x"}})
    members = {"glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3"}
    if rewritten:
        pick = data["model"]
        assert pick in members
        assert data["fallbacks"] == [{pick: sorted(members - {pick}, key=["glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3"].index)}]
        assert data["metadata"] == {"user_api_key": "x", "ovid_auto": True}
    else:
        assert data["model"] == "auto" and "fallbacks" not in data


def test_auto_rewrite_toggle_and_weights_are_editable(hook):
    h, r, _ = hook
    set_plan(r, "free", auto_oss=True)
    r.hset(plans.LIMITS_HASH, "auto_oss_members",
           json.dumps([{"model": "minimax-m3", "weight": 1000}, {"model": "glm-5.3-flash", "weight": 0.001}]))
    picks = [pre(make_hook(r, seed=i), "u", "auto")["model"] for i in range(20)]
    assert picks.count("minimax-m3") >= 19
    data = pre(make_hook(r, seed=0), "u", "auto")
    assert data["fallbacks"] == [{"minimax-m3": ["glm-5.3-flash"]}]


def test_only_auto_is_rewritten(hook):
    h, r, _ = hook
    r.set("user:p:tier", "pro")
    assert pre(h, "p", "gemini-3.8-flash") == {"model": "gemini-3.8-flash"}


@pytest.mark.parametrize("members,groups", [
    ([], GROUPS),                                                    # empty list
    ([{"model": "gone-1", "weight": 1}], GROUPS),                    # member not in LiteLLM
    ("not json", GROUPS),                                            # invalid setting
])
def test_auto_falls_back_to_plain_auto(hook, members, groups):
    h, r, _ = hook
    r.set("user:p:tier", "pro")
    r.hset(plans.LIMITS_HASH, "auto_oss_members", members if isinstance(members, str) else json.dumps(members))
    r.set(plans.MODEL_GROUPS_KEY, json.dumps(groups))
    data = pre(h, "p", "auto")
    assert data["model"] == "auto" and "fallbacks" not in data


def test_missing_members_are_skipped(hook):
    h, r, _ = hook
    r.set("user:p:tier", "pro")
    r.set(plans.MODEL_GROUPS_KEY, json.dumps(["auto", "minimax-m3"]))
    data = pre(h, "p", "auto")
    assert data["model"] == "minimax-m3" and "fallbacks" not in data


def test_rewritten_requests_tallied_as_auto(hook):
    h, r, _ = hook
    r.set("user:p:tier", "pro")
    success(h, "p", "glm-5.3-flash", 0.01, auto=True)
    success(h, "p", "glm-5.3-flash", 0.01, auto=True)
    success(h, "p", "glm-5.3-flash", 0.01)
    assert r.hgetall("pool:p:auto") == {"glm-5.3-flash": "2"}


def test_window_rolls_over(hook):
    h, r, clock = hook
    success(h, "u", "glm-5.3-flash", 1.0)
    assert rejected(h, "u", "glm-5.3-flash")
    clock.t += 86401
    assert pre(h, "u", "glm-5.3-flash")


def test_admin_reset_clears_hook_state(hook):
    h, r, _ = hook
    success(h, "u", "glm-5.3-flash", 1.0)
    r.delete("pool:u:spend")  # what mint's reset does
    assert pre(h, "u", "glm-5.3-flash")


def test_settings_change_applies_after_cache_ttl(hook):
    h, r, clock = hook
    success(h, "u", "glm-5.3-flash", 1.0)
    assert rejected(h, "u", "glm-5.3-flash")
    r.set(plans.BASE_BUDGET_KEY, "10")
    clock.t += ovid_pools.SETTINGS_TTL_S + 1
    assert pre(h, "u", "glm-5.3-flash")


def test_custom_user_overrides_respected(hook):
    h, r, _ = hook
    r.set("user:u:dailyUsd", "4")
    success(h, "u", "glm-5.3-flash", 3.9)
    assert pre(h, "u", "glm-5.3-flash")
    r.set("user:p:tier", "pro")
    r.set("user:p:pools", json.dumps({"mult": 0}))
    assert rejected(h, "p", "glm-5.3-flash").type == "daily_limit_reached"
    r.set("user:q:tier", "pro")
    r.set("user:q:pools", json.dumps({"auto_oss": False}))
    assert pre(h, "q", "auto")["model"] == "auto"


def test_fail_open_and_master_key_passthrough(hook):
    h, r, clock = hook
    broken = ovid_pools.OvidPools(redis_client=AsyncRedis(r, fail=True), clock=clock)
    assert pre(broken, "u", "glm-5.3-flash") == {"model": "glm-5.3-flash"}
    success(broken, "u", "glm-5.3-flash", 5)  # no raise
    assert run(h.async_pre_call_hook(key(None), None, {"model": "x"}, "acompletion")) == {"model": "x"}
