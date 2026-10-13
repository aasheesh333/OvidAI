"""LiteLLM pools hook: frontier sub-cap + fallback code, slow-mode flagging,
auto attribution and oss routing, fail-open, live settings."""
import asyncio
import json
import sys
import types

import pytest

from conftest import MINT_DIR, AsyncRedis, MemoryRedis

sys.path.insert(0, str(MINT_DIR / "litellm_hook"))
sys.path.insert(0, str(MINT_DIR))
import ovid_plans as plans  # noqa: E402
import ovid_pools  # noqa: E402

NOW = 1_800_000_000.0
PUBLIC_MAP = {"prov/glm-5.3-flash": "glm-5.3-flash", "prov/minimax-m3": "minimax-m3",
              "prov/gemini-3.8-flash": "gemini-3.8-flash", "prov/img-1": "ovid-image"}


class Clock:
    def __init__(self):
        self.t = NOW

    def __call__(self):
        return self.t


@pytest.fixture
def hook():
    r = MemoryRedis()
    s = plans.parse_settings({}, "1.0")  # free allowance $1/24h
    base, fields = plans.serialize_settings(s)
    r.set(plans.BASE_BUDGET_KEY, base)
    r.hset(plans.LIMITS_HASH, mapping=fields)
    r.set(plans.PUBLIC_MAP_KEY, json.dumps(PUBLIC_MAP))
    clock = Clock()
    h = ovid_pools.OvidPools(redis_client=AsyncRedis(r), clock=clock)
    return h, r, clock


def run(coro):
    return asyncio.run(coro)


def key(uid):
    return types.SimpleNamespace(user_id=uid)


def pre(h, uid, model, call_type="acompletion"):
    return run(h.async_pre_call_hook(key(uid), None, {"model": model}, call_type))


def success(h, uid, group, served, cost, call_type="acompletion"):
    kwargs = {"standard_logging_object": {"metadata": {"user_api_key_user_id": uid},
                                          "response_cost": cost, "model_group": group,
                                          "model": served, "call_type": call_type}}
    run(h.async_log_success_event(kwargs, None, None, None))


def rejected(h, uid, model, call_type="acompletion"):
    with pytest.raises(ovid_pools.ProxyException) as e:
        pre(h, uid, model, call_type)
    return e.value


def test_free_frontier_subcap_rejects_with_code_and_allows_auto_and_oss(hook):
    h, r, clock = hook
    assert pre(h, "u", "gemini-3.8-flash") == {"model": "gemini-3.8-flash"}
    success(h, "u", "gemini-3.8-flash", "prov/gemini-3.8-flash", 0.25)  # 25% of $1
    err = rejected(h, "u", "gemini-3.8-flash")
    assert err.type == "frontier_limit_reached" and err.code == "429"
    assert err.headers["x-ovid-error"] == "frontier_limit_reached"
    resets = err.headers["x-ovid-resets-at"]
    assert resets == ovid_pools._iso(NOW + 86400) and err.provider_specific_fields["resets_at"] == resets
    assert "resets_at=" in err.message
    assert pre(h, "u", "auto")["model"] == "auto"
    assert pre(h, "u", "glm-5.3-flash")["model"] == "glm-5.3-flash"
    assert rejected(h, "u", "ovid-image", "aimage_generation").type == "frontier_limit_reached"


def test_starter_alias_uses_multiplied_allowance(hook):
    h, r, _ = hook
    r.set("user:s:tier", "3x")
    success(h, "s", "gemini-3.8-flash", "prov/gemini-3.8-flash", 0.5)   # < 25% of $3
    assert pre(h, "s", "gemini-3.8-flash")
    success(h, "s", "gemini-3.8-flash", "prov/gemini-3.8-flash", 0.25)
    assert rejected(h, "s", "gemini-3.8-flash").type == "frontier_limit_reached"


def test_shared_allowance_used_up_blocks_everything(hook):
    h, r, _ = hook
    success(h, "u", "glm-5.3-flash", "prov/glm-5.3-flash", 1.0)
    assert rejected(h, "u", "glm-5.3-flash").type == "daily_limit_reached"
    assert rejected(h, "u", "auto").type == "daily_limit_reached"


def test_pro_frontier_pool_exhausted_oss_never_blocked(hook):
    h, r, _ = hook
    r.set("user:p:tier", "7x")
    success(h, "p", "gemini-3.8-flash", "prov/gemini-3.8-flash", 1.5)
    assert rejected(h, "p", "gemini-3.8-flash").type == "frontier_limit_reached"
    assert rejected(h, "p", "ovid-image", "aimage_generation").type == "frontier_limit_reached"
    success(h, "p", "glm-5.3-flash", "prov/glm-5.3-flash", 2.5)  # over the $2 oss pool
    assert pre(h, "p", "glm-5.3-flash")["model"] == "glm-5.3-flash"   # slow mode, not a block
    assert r.sismember(plans.SLOW_PENDING, "p")


def test_oss_below_pool_does_not_flag_slow(hook):
    h, r, _ = hook
    r.set("user:p:tier", "max")
    success(h, "p", "glm-5.3-flash", "prov/glm-5.3-flash", 2.9)
    assert not r.sismember(plans.SLOW_PENDING, "p")


def test_auto_counted_by_served_model_class(hook):
    h, r, _ = hook
    success(h, "u", "auto", "prov/minimax-m3", 0.1)
    success(h, "u", "auto", "prov/gemini-3.8-flash", 0.05)
    success(h, "u", "auto", "prov/unknown-model", 0.02)
    success(h, "u", "ovid-image", "prov/img-1", 0.04, "aimage_generation")
    assert float(r.get("pool:u:spend:oss")) == pytest.approx(0.1)
    assert float(r.get("pool:u:spend:frontier")) == pytest.approx(0.11)


def test_auto_routed_to_oss_group_for_split_plans(hook):
    h, r, _ = hook
    r.hset(plans.LIMITS_HASH, "auto_oss_group", "auto-oss")
    r.set("user:p:tier", "pro")
    assert pre(h, "p", "auto")["model"] == "auto-oss"
    assert pre(h, "u", "auto")["model"] == "auto"  # free plan untouched


def test_window_rolls_over(hook):
    h, r, clock = hook
    success(h, "u", "gemini-3.8-flash", "prov/gemini-3.8-flash", 0.3)
    assert rejected(h, "u", "gemini-3.8-flash")
    clock.t += 86401
    assert pre(h, "u", "gemini-3.8-flash")


def test_admin_reset_clears_hook_state(hook):
    h, r, _ = hook
    success(h, "u", "gemini-3.8-flash", "prov/gemini-3.8-flash", 0.3)
    r.delete("pool:u:spend:frontier")  # what mint's reset does
    assert pre(h, "u", "gemini-3.8-flash")


def test_settings_change_applies_after_cache_ttl(hook):
    h, r, clock = hook
    success(h, "u", "gemini-3.8-flash", "prov/gemini-3.8-flash", 0.3)
    assert rejected(h, "u", "gemini-3.8-flash")
    r.set(plans.BASE_BUDGET_KEY, "10")       # owner raises the free allowance
    clock.t += ovid_pools.SETTINGS_TTL_S + 1
    assert pre(h, "u", "gemini-3.8-flash")


def test_custom_user_overrides_respected(hook):
    h, r, _ = hook
    r.set("user:u:dailyUsd", "4")
    success(h, "u", "gemini-3.8-flash", "prov/gemini-3.8-flash", 0.9)
    assert pre(h, "u", "gemini-3.8-flash")
    r.set("user:p:tier", "pro")
    r.set("user:p:pools", json.dumps({"frontier_usd": 0}))
    assert rejected(h, "p", "gemini-3.8-flash").type == "frontier_limit_reached"


def test_fail_open_and_master_key_passthrough(hook):
    h, r, clock = hook
    broken = ovid_pools.OvidPools(redis_client=AsyncRedis(r, fail=True), clock=clock)
    assert pre(broken, "u", "gemini-3.8-flash") == {"model": "gemini-3.8-flash"}
    success(broken, "u", "gemini-3.8-flash", "prov/gemini-3.8-flash", 5)  # no raise
    assert run(h.async_pre_call_hook(key(None), None, {"model": "x"}, "acompletion")) == {"model": "x"}
