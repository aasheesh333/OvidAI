"""LiteLLM proxy hook: enforces each user's Ovid plan allowance in the request path.

Loaded by LiteLLM from its config directory (``litellm_settings.callbacks:
["ovid_pools.proxy_handler_instance"]``) next to ``ovid_plans.py``. It reads the
same Redis settings mint writes (db ``OVID_POOLS_REDIS_DB``, default 2), so any
/admin change applies within ``OVID_POOLS_SETTINGS_TTL_S`` (5 s).

Every plan is ONE allowance per window, consumed at each model's LiteLLM price.
Pre-call: allowance used up → ``daily_limit_reached`` (HTTP 429), unless the
plan has slow mode on, in which case the request goes through and mint has
lowered the key's rate limits. The error is OpenAI-shaped:
    {"error": {"message": "daily_limit_reached: ... resets_at=<ISO>",
               "type": "daily_limit_reached", "param": "model", "code": "429",
               "provider_specific_fields": {"ovid_error": "...", "resets_at": "<ISO>"}}}
with headers ``x-ovid-error``, ``x-ovid-resets-at`` and ``retry-after``.
Hidden auto routing: for plans with ``auto_oss`` on, a request for ``auto`` is
rewritten to a weighted-random member of ``auto_oss_members`` and
``data["fallbacks"] = [{picked: [other members]}]`` is set. LiteLLM 1.105's
Router reads per-request ``fallbacks`` from the call kwargs
(``async_function_with_fallbacks``: ``kwargs.get("fallbacks", self.fallbacks)``;
plain-string lists keep only the last entry, so the dict form is used).
Members not in ``config:model_groups`` (published by mint from /model/info) are
skipped; with no usable member the request stays plain ``auto``. Rewritten
requests are tagged ``metadata.ovid_auto`` and counted per served model in
``pool:{uid}:auto`` so mint can still report them as auto requests.
Success: adds the request's LiteLLM cost to the user's counter (ONE counter per
user across android + web keys) and flags slow-mode plans that crossed their
allowance so mint lowers their limits.

Fail-open: any Redis/settings error lets the request through (LiteLLM key and
user budgets remain the hard backstop).
"""
from __future__ import annotations

import datetime
import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ovid_plans as plans  # noqa: E402

try:  # inside the LiteLLM proxy
    from litellm.integrations.custom_logger import CustomLogger
    from litellm.proxy._types import ProxyException
except ImportError:  # unit tests without litellm installed
    class CustomLogger:  # type: ignore[no-redef]
        pass

    class ProxyException(Exception):  # type: ignore[no-redef]
        def __init__(self, message, type, param, code=None, headers=None,
                     openai_code=None, provider_specific_fields=None):
            super().__init__(message)
            self.message, self.type, self.param = message, type, param
            self.code, self.headers = str(code), headers or {}
            self.provider_specific_fields = provider_specific_fields

SETTINGS_TTL_S = float(os.environ.get("OVID_POOLS_SETTINGS_TTL_S", "5"))


def _iso(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z")


class OvidPools(CustomLogger):
    def __init__(self, redis_client=None, clock=time.time, rng=None):
        super().__init__()
        self._r = redis_client
        self._clock = clock
        self._rng = rng or random.Random()
        self._cache: tuple[float, dict | None] = (0.0, None)

    def _redis(self):
        if self._r is None:
            import redis.asyncio as aioredis
            self._r = aioredis.Redis(
                host=os.environ.get("REDIS_HOST", "redis"),
                port=int(os.environ.get("REDIS_PORT", "6379")),
                password=os.environ.get("REDIS_PASSWORD") or None,
                db=int(os.environ.get("OVID_POOLS_REDIS_DB", "2")),
                decode_responses=True)
        return self._r

    async def _settings(self) -> dict:
        now = self._clock()
        at, s = self._cache
        if s is not None and now - at < SETTINGS_TTL_S:
            return s
        r = self._redis()
        s = plans.parse_settings(await r.hgetall(plans.LIMITS_HASH), await r.get(plans.BASE_BUDGET_KEY))
        self._cache = (now, s)
        return s

    async def _pools(self, r, uid: str, s: dict) -> dict:
        plan = plans.find_plan(s, await r.get(f"user:{uid}:tier"))
        raw_daily = await r.get(f"user:{uid}:dailyUsd")
        try:
            daily = float(raw_daily) if raw_daily not in (None, "") else s["free_daily_usd"]
        except ValueError:
            daily = s["free_daily_usd"]
        try:
            override = json.loads(await r.get(f"user:{uid}:pools") or "null")
        except ValueError:
            override = None
        return plans.user_pools(s, plan, daily, override if isinstance(override, dict) else None)

    async def _window(self, r, uid: str, pools: dict, create: bool) -> tuple[float, float] | None:
        """(start, end) epoch of the live window; same rules as mint."""
        k = plans.pool_keys(uid)
        secs = int(pools["window_hours"] * 3600)
        now = self._clock()
        raw = await r.get(k["start"])
        start = float(raw) if raw else None
        if start is None or start + secs <= now:
            if start is not None:
                await r.delete(k["start"], k["spend"], k["auto"])
            if not create:
                return None
            await r.set(k["start"], str(int(now)), nx=True, ex=secs)
            start = float(await r.get(k["start"]) or now)
        return start, start + secs

    async def _spend(self, r, uid: str) -> float:
        try:
            return float(await r.get(plans.pool_keys(uid)["spend"]) or 0)
        except ValueError:
            return 0.0

    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type):
        uid = getattr(user_api_key_dict, "user_id", None)
        if not uid:
            return data
        try:
            r = self._redis()
            s = await self._settings()
            pools = await self._pools(r, uid, s)
            win = await self._window(r, uid, pools, create=False)
            spent = await self._spend(r, uid) if win else 0.0
            decision = plans.decide(pools, spent)
        except Exception as e:  # noqa: BLE001 — fail open
            print(f"[ovid_pools] pre-call skipped: {type(e).__name__}", flush=True)
            return data
        if decision["action"] == "reject":
            code = decision["code"]
            end = win[1] if win else self._clock() + pools["window_hours"] * 3600
            resets_at = _iso(end)
            raise ProxyException(
                message=f"{code}: this plan's allowance is used up; resets_at={resets_at}",
                type=code, param="model", code=429,
                headers={"x-ovid-error": code, "x-ovid-resets-at": resets_at,
                         "retry-after": str(max(1, int(end - self._clock())))},
                provider_specific_fields={"ovid_error": code, "resets_at": resets_at})
        if pools.get("auto_oss") and data.get("model") == plans.AUTO_MODEL:
            try:
                await self._route_auto(data, s)
            except Exception as e:  # noqa: BLE001 — never fail: stay on plain auto
                print(f"[ovid_pools] auto routing skipped: {type(e).__name__}", flush=True)
        return data

    async def _route_auto(self, data: dict, s: dict) -> None:
        raw = await self._redis().get(plans.MODEL_GROUPS_KEY)
        try:
            known = set(json.loads(raw)) if raw else None
        except (TypeError, ValueError):
            known = None
        choice = plans.pick_auto_member(s.get("auto_oss_members") or [], known, self._rng)
        if not choice:
            return
        pick, rest = choice
        data["model"] = pick
        if rest:
            data["fallbacks"] = [{pick: rest}]
        meta = data.get("metadata")
        if not isinstance(meta, dict):
            meta = {}
            data["metadata"] = meta
        meta["ovid_auto"] = True

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        try:
            slo = kwargs.get("standard_logging_object") or {}
            meta = slo.get("metadata") or {}
            uid = meta.get("user_api_key_user_id")
            cost = float(slo.get("response_cost") or kwargs.get("response_cost") or 0)
            if not uid or cost <= 0:
                return
            r = self._redis()
            s = await self._settings()
            pools = await self._pools(r, uid, s)
            _start, end = await self._window(r, uid, pools, create=True)
            key = plans.pool_keys(uid)["spend"]
            total = float(await r.incrbyfloat(key, cost))
            await r.expire(key, max(1, int(end - self._clock())))
            if self._was_auto(kwargs, slo):
                served = str(slo.get("model_group") or slo.get("model") or plans.AUTO_MODEL)
                akey = plans.pool_keys(uid)["auto"]
                await r.hincrby(akey, served, 1)
                await r.expire(akey, max(1, int(end - self._clock())))
            if pools["slow_mode"] and total >= pools["all"]:
                await r.sadd(plans.SLOW_PENDING, uid)
        except Exception as e:  # noqa: BLE001 — accounting must never break responses
            print(f"[ovid_pools] accounting skipped: {type(e).__name__}", flush=True)


    @staticmethod
    def _was_auto(kwargs: dict, slo: dict) -> bool:
        for meta in ((kwargs.get("litellm_params") or {}).get("metadata"),
                     (slo.get("metadata") or {}).get("requester_metadata"),
                     kwargs.get("metadata")):
            if isinstance(meta, dict) and meta.get("ovid_auto"):
                return True
        return False


proxy_handler_instance = OvidPools()
