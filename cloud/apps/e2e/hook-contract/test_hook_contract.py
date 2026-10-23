"""P9 Task 17 - the real-Python hook contract against TypeScript-written db2.

The TypeScript side (``seed.ts``, invoked by ``src/money.test.ts``) writes
``config:limits`` / ``config:base_daily_usd`` / ``config:model_groups`` and the
per-user ``user:{uid}:tier`` keys through mint's own Postgres->Redis
projection. This suite then instantiates the UNMODIFIED
``server/mint/litellm_hook/ovid_pools.py`` against that same Redis and asserts
the six contracts pinned by the plan:

  (a) under allowance -> data passes through unchanged
  (b) spend >= allowance (non-slow) -> daily_limit_reached 429 + exact headers
  (c) slow-mode plan over allowance -> allowed + pools:slow_pending flag
  (d) auto_oss rewrite -> member + fallbacks + metadata.ovid_auto; unknown /
      empty / invalid members -> plain auto, never a failure
  (e) success accounting -> INCRBYFLOAT exact cost + window TTL; auto tally
  (f) settings parse -> TS-written values equal the Python baseline
      field-for-field (the shape-drift canary)

Run from the repo root::

    HOOK_CONTRACT_REDIS_URL=redis://127.0.0.1:6390/9 \\
    HOOK_CONTRACT_FIXTURE='{"freeUid":...}' \\
    python3 -m pytest cloud/apps/e2e/hook-contract -q

The harness is skipped when HOOK_CONTRACT_REDIS_URL is unset (conftest.py).
No test may weaken an assertion to make the Python hook pass: a mismatch here
is a real TS<->Python parity bug.
"""
from __future__ import annotations

import asyncio
import copy
import json
import os
import random
import types
from typing import Any, Callable

import pytest
import redis.asyncio as aioredis

import ovid_plans as plans
import ovid_pools

# Deterministic wall clock: the hook's window/header math is pinned to it.
NOW = 1_800_000_000.0
WINDOW_HOURS = 24
WINDOW_SECONDS = WINDOW_HOURS * 3600
FREE_DAILY = 1.0
GROUPS = ["auto", "glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3", "ovid-image"]

# The settings TS writes (seed.ts HOOK_CONTRACT_SETTINGS). Custom values prove
# every scalar crosses the boundary, not just the defaults.
SCALAR_VALUES: dict[str, Any] = {
    "free_monthly_cap_usd": 12.5,
    "est_input_tokens": 1234,
    "est_output_tokens": 600,
    "est_image_tokens": 1500,
    "slow_rpm": 7,
    "slow_tpm": 200_000,
    "slow_parallel": 2,
    "normal_rpm": 111,
    "normal_tpm": 4_000_000,
    "normal_parallel": 16,
    "hard_ceiling_mult": 2.5,
}
MEMBERS = [
    {"model": "glm-5.3-flash", "weight": 1.0},
    {"model": "deepseek-v4.1-flash", "weight": 1.0},
    {"model": "minimax-m3", "weight": 1.0},
]
PLANS = [
    {"id": "free", "name": "Free", "price_usd": 0, "enabled": True, "aliases": [],
     "window_hours": WINDOW_HOURS, "mult": 1, "slow_mode": False, "auto_oss": False},
    {"id": "starter", "name": "Starter", "price_usd": 5, "enabled": True,
     "aliases": ["3x"], "window_hours": WINDOW_HOURS, "mult": 1.5,
     "slow_mode": True, "auto_oss": False},
    {"id": "pro", "name": "Pro", "price_usd": 25, "enabled": True,
     "aliases": ["7x"], "window_hours": WINDOW_HOURS, "mult": 5,
     "slow_mode": False, "auto_oss": True},
]

# The Python-seeded baseline the parsed TS projection must equal exactly.
EXPECTED_SETTINGS = plans.validate_settings(
    {
        "free_daily_usd": FREE_DAILY,
        "auto_oss_members": MEMBERS,
        "plans": PLANS,
        **SCALAR_VALUES,
    }
)


class Clock:
    def __init__(self, now: float = NOW) -> None:
        self.t = now

    def __call__(self) -> float:
        return self.t


def _run(coro):
    return asyncio.run(coro)


def _hook(client: aioredis.Redis, clock: Clock | None = None, seed: int = 1) -> ovid_pools.OvidPools:
    return ovid_pools.OvidPools(
        redis_client=client,
        clock=clock or Clock(),
        rng=random.Random(seed),
    )


def _key(uid: str) -> types.SimpleNamespace:
    return types.SimpleNamespace(user_id=uid)


async def _pre(
    hook: ovid_pools.OvidPools,
    uid: str,
    model: str,
    call_type: str = "acompletion",
    data: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return await hook.async_pre_call_hook(
        _key(uid), None, {"model": model, **(data or {})}, call_type
    )


async def _success(
    hook: ovid_pools.OvidPools,
    uid: str,
    group: str,
    cost: Any,
    call_type: str = "acompletion",
    auto: bool = False,
) -> None:
    kwargs = {
        "standard_logging_object": {
            "metadata": {"user_api_key_user_id": uid},
            "response_cost": cost,
            "model_group": group,
            "model": f"prov/{group}",
            "call_type": call_type,
        },
        "litellm_params": {"metadata": {"ovid_auto": True} if auto else {}},
    }
    await hook.async_log_success_event(kwargs, None, None, None)


@pytest.fixture(scope="module")
def fixture_uids() -> dict[str, str]:
    raw = os.environ.get("HOOK_CONTRACT_FIXTURE")
    assert raw, "HOOK_CONTRACT_FIXTURE must carry the TS-seeded uid map"
    uids = json.loads(raw)
    for name in ("freeUid", "slowUid", "autoUid", "accUid", "autoAccUid"):
        assert isinstance(uids.get(name), str) and uids[name], f"fixture missing {name}"
    return uids


@pytest.fixture()
def redis_url() -> str:
    return os.environ["HOOK_CONTRACT_REDIS_URL"]


def _client(url: str) -> aioredis.Redis:
    return aioredis.Redis.from_url(url, decode_responses=True)


# ---------------------------------------------------------------------------
# (a) under allowance: pass-through
# ---------------------------------------------------------------------------
def test_a_under_allowance_passes_data_through_unchanged(fixture_uids, redis_url):
    uid = fixture_uids["freeUid"]

    async def scenario() -> None:
        client = _client(redis_url)
        try:
            hook = _hook(client)
            data = {
                "model": "glm-5.3-flash",
                "messages": [{"role": "user", "content": "hello"}],
                "metadata": {"trace": "t17"},
                "temperature": 0.2,
            }
            before = copy.deepcopy(data)
            out = await hook.async_pre_call_hook(_key(uid), None, data, "acompletion")
            assert out == before, "the hook mutated a request that is under allowance"
            assert out is data
        finally:
            await client.aclose()

    _run(scenario())


# ---------------------------------------------------------------------------
# (b) spend >= allowance on a non-slow plan -> daily_limit_reached
# ---------------------------------------------------------------------------
def test_b_over_allowance_rejects_with_exact_error_contract(fixture_uids, redis_url):
    uid = fixture_uids["freeUid"]

    async def scenario() -> None:
        client = _client(redis_url)
        try:
            # A live window anchored at NOW, fully spent (allowance is $1).
            await client.set(f"pool:{uid}:start", str(int(NOW)))
            await client.set(f"pool:{uid}:spend", "1.0")
            hook = _hook(client)

            with pytest.raises(ovid_pools.ProxyException) as caught:
                await _pre(hook, uid, "glm-5.3-flash")
            err = caught.value
            resets_at = ovid_pools._iso(NOW + WINDOW_SECONDS)
            assert err.type == "daily_limit_reached"
            assert err.code == "429"
            assert err.param == "model"
            assert err.headers["x-ovid-error"] == "daily_limit_reached"
            assert err.headers["x-ovid-resets-at"] == resets_at
            assert int(err.headers["retry-after"]) >= 1
            assert err.headers["retry-after"] == str(WINDOW_SECONDS)
            assert err.provider_specific_fields == {
                "ovid_error": "daily_limit_reached",
                "resets_at": resets_at,
            }
            # resets_at is an ISO-8601 UTC instant ending in Z (no fraction).
            assert resets_at.endswith("Z") and "." not in resets_at

            # Every model class is subject to the SAME allowance.
            for model, call_type in (("auto", "acompletion"), ("ovid-image", "aimage_generation")):
                with pytest.raises(ovid_pools.ProxyException) as caught_other:
                    await _pre(hook, uid, model, call_type)
                assert caught_other.value.type == "daily_limit_reached"
        finally:
            await client.aclose()

    _run(scenario())


# ---------------------------------------------------------------------------
# (c) slow-mode plan: never blocks, flags pools:slow_pending
# ---------------------------------------------------------------------------
def test_c_slow_mode_plan_allows_past_allowance_and_flags_pending(fixture_uids, redis_url):
    uid = fixture_uids["slowUid"]  # tier "3x" -> starter (slow_mode=True, allowance $3)

    async def scenario() -> None:
        client = _client(redis_url)
        try:
            hook = _hook(client)
            await _success(hook, uid, "glm-5.3-flash", 2.9)
            assert not await client.sismember(plans.SLOW_PENDING, uid)
            await _success(hook, uid, "glm-5.3-flash", 0.2)  # total 3.1 > 3.0
            assert await client.sismember(plans.SLOW_PENDING, uid)

            out = await _pre(hook, uid, "gemini-3.8-flash")
            assert out["model"] == "gemini-3.8-flash", "slow mode must never reject"
        finally:
            await client.aclose()

    _run(scenario())


# ---------------------------------------------------------------------------
# (d) auto_oss routing driven by TS-published config:model_groups
# ---------------------------------------------------------------------------
def test_d_auto_routing_uses_ts_model_groups_and_degrades_safely(fixture_uids, redis_url):
    uid = fixture_uids["autoUid"]  # tier "7x" -> pro (auto_oss=True)
    order = [m["model"] for m in MEMBERS]

    async def scenario() -> None:
        client = _client(redis_url)
        try:
            data = await _pre(
                _hook(client, seed=0), uid, "auto", data={"metadata": {"user_api_key": "x"}}
            )
            picked = data["model"]
            assert picked in order, f"auto was not rewritten to a known member: {picked!r}"
            assert data["fallbacks"] == [{picked: [m for m in order if m != picked]}]
            assert data["metadata"] == {"user_api_key": "x", "ovid_auto": True}

            # A member absent from config:model_groups is skipped.
            await client.set(plans.MODEL_GROUPS_KEY, json.dumps(["auto", "minimax-m3"]))
            only = await _pre(_hook(client, seed=0), uid, "auto")
            assert only["model"] == "minimax-m3"
            assert "fallbacks" not in only

            original_members = await client.hget(plans.LIMITS_HASH, "auto_oss_members")
            assert original_members is not None
            try:
                # Empty member list -> plain auto, never a failure. A FRESH
                # hook each time: the hook caches settings for SETTINGS_TTL_S
                # against its (fixed) clock, so a reused hook would still see
                # the previous member list.
                await client.hset(plans.LIMITS_HASH, "auto_oss_members", "[]")
                plain = await _pre(_hook(client, seed=0), uid, "auto")
                assert plain["model"] == "auto" and "fallbacks" not in plain

                # Invalid stored JSON -> plain auto, never a failure.
                await client.hset(plans.LIMITS_HASH, "auto_oss_members", "not json")
                invalid = await _pre(_hook(client, seed=0), uid, "auto")
                assert invalid["model"] == "auto" and "fallbacks" not in invalid
            finally:
                await client.hset(plans.LIMITS_HASH, "auto_oss_members", original_members)
                await client.set(plans.MODEL_GROUPS_KEY, json.dumps(sorted(GROUPS)))
        finally:
            await client.aclose()

    _run(scenario())


# ---------------------------------------------------------------------------
# (e) success accounting: exact counter, window TTL, auto tally
# ---------------------------------------------------------------------------
def test_e_success_accounting_is_exact_and_window_scoped(fixture_uids, redis_url):
    uid = fixture_uids["accUid"]
    auto_uid = fixture_uids["autoAccUid"]

    async def scenario() -> None:
        client = _client(redis_url)
        try:
            hook = _hook(client)
            await _success(hook, uid, "glm-5.3-flash", "0.1")
            await _success(hook, uid, "glm-5.3-flash", "0.2")
            spend_key = plans.pool_keys(uid)["spend"]
            # Redis INCRBYFLOAT's canonical result, compared as the EXACT string.
            assert await client.get(spend_key) == "0.3"
            ttl = await client.ttl(spend_key)
            assert 86_000 <= ttl <= WINDOW_SECONDS, f"spend TTL outside window: {ttl}"
            assert await client.get(plans.pool_keys(uid)["start"]) == str(int(NOW))

            # Auto-rewritten successes are tallied per served model.
            await _success(hook, auto_uid, "glm-5.3-flash", 0.01, auto=True)
            await _success(hook, auto_uid, "glm-5.3-flash", 0.01, auto=True)
            await _success(hook, auto_uid, "glm-5.3-flash", 0.01)
            auto_key = plans.pool_keys(auto_uid)["auto"]
            assert await client.hgetall(auto_key) == {"glm-5.3-flash": "2"}
            auto_ttl = await client.ttl(auto_key)
            assert 86_000 <= auto_ttl <= WINDOW_SECONDS
        finally:
            await client.aclose()

    _run(scenario())


# ---------------------------------------------------------------------------
# (f) settings shape-drift canary
# ---------------------------------------------------------------------------
def test_f_parse_settings_matches_python_baseline_field_for_field(redis_url):
    async def scenario() -> None:
        client = _client(redis_url)
        try:
            raw = await client.hgetall(plans.LIMITS_HASH)
            base = await client.get(plans.BASE_BUDGET_KEY)
        finally:
            await client.aclose()

        actual = plans.parse_settings(raw, base)
        assert actual == EXPECTED_SETTINGS
        # Compare each section explicitly so a failure names the drifted field.
        for name, expected in EXPECTED_SETTINGS.items():
            assert actual.get(name) == expected, (
                f"settings field {name!r} drifted: expected {expected!r}, got {actual.get(name)!r}"
            )
        assert actual["plans"] == EXPECTED_SETTINGS["plans"]
        assert actual["auto_oss_members"] == EXPECTED_SETTINGS["auto_oss_members"]
        # Unknown stored fields are ignored by parse_settings; TS must not leak any.
        known = set(SCALAR_VALUES) | {"plans", "auto_oss_members"}
        assert set(raw) <= known, f"unexpected config:limits fields: {sorted(set(raw) - known)}"

    _run(scenario())
