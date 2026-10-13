"""LiteLLM proxy hook: enforces Ovid plan pools in the request path.

Loaded by LiteLLM from its config directory (``litellm_settings.callbacks:
["ovid_pools.proxy_handler_instance"]``) next to ``ovid_plans.py``. It reads the
same Redis settings mint writes (db ``OVID_POOLS_REDIS_DB``, default 2), so any
/admin change applies within ``OVID_POOLS_SETTINGS_TTL_S`` (5 s).

Pre-call (before any provider is called):
  * shared plans: whole allowance used → ``daily_limit_reached``; frontier
    share used and a frontier model (or image) requested →
    ``frontier_limit_reached``. Auto and oss models keep the remainder.
  * split plans: frontier pool used → ``frontier_limit_reached`` for frontier
    models / images; ``auto`` is routed to the oss-only group when the owner set
    ``auto_oss_group``. The oss pool never blocks (slow mode instead).
  Rejections are OpenAI-shaped errors, HTTP 429:
    {"error": {"message": "frontier_limit_reached: ... resets_at=<ISO>",
               "type": "frontier_limit_reached", "param": "model", "code": "429",
               "provider_specific_fields": {"ovid_error": "...", "resets_at": "<ISO>"}}}
  with headers ``x-ovid-error``, ``x-ovid-resets-at`` and ``retry-after``.
Success: adds the request's LiteLLM cost to the user's pool counter for the
class of the model that actually served it (auto → its member), and flags the
user for slow mode (mint applies lower key limits) when a split plan crosses
its oss pool.

Fail-open: any Redis/settings error lets the request through (LiteLLM key and
user budgets remain the hard backstop).
"""
from __future__ import annotations

import datetime
import json
import os
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
    def __init__(self, redis_client=None, clock=time.time):
        super().__init__()
        self._r = redis_client
        self._clock = clock
        self._cache: tuple[float, dict | None, dict] = (0.0, None, {})

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

    async def _settings(self) -> tuple[dict, dict]:
        now = self._clock()
        at, s, pmap = self._cache
        if s is not None and now - at < SETTINGS_TTL_S:
            return s, pmap
        r = self._redis()
        s = plans.parse_settings(await r.hgetall(plans.LIMITS_HASH), await r.get(plans.BASE_BUDGET_KEY))
        try:
            pmap = json.loads(await r.get(plans.PUBLIC_MAP_KEY) or "{}")
        except ValueError:
            pmap = {}
        self._cache = (now, s, pmap)
        return s, pmap

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
                await r.delete(k["start"], k["oss"], k["frontier"])
            if not create:
                return None
            await r.set(k["start"], f"{now:.3f}", nx=True, ex=secs)
            start = float(await r.get(k["start"]) or now)
        return start, start + secs

    async def _spend(self, r, uid: str) -> dict:
        k = plans.pool_keys(uid)
        out = {}
        for c in plans.CLASSES:
            try:
                out[c] = float(await r.get(k[c]) or 0)
            except ValueError:
                out[c] = 0.0
        return out

    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type):
        uid = getattr(user_api_key_dict, "user_id", None)
        if not uid:
            return data
        try:
            r = self._redis()
            s, _ = await self._settings()
            pools = await self._pools(r, uid, s)
            win = await self._window(r, uid, pools, create=False)
            spend = await self._spend(r, uid) if win else {"oss": 0.0, "frontier": 0.0}
            decision = plans.decide(s, pools, spend, str(data.get("model") or ""), str(call_type or ""))
        except Exception as e:  # noqa: BLE001 — fail open
            print(f"[ovid_pools] pre-call skipped: {type(e).__name__}", flush=True)
            return data
        if decision["action"] == "reject":
            code = decision["code"]
            end = win[1] if win else self._clock() + pools["window_hours"] * 3600
            resets_at = _iso(end)
            raise ProxyException(
                message=f"{code}: this plan's {'frontier ' if code.startswith('frontier') else ''}"
                        f"allowance is used up; resets_at={resets_at}",
                type=code, param="model", code=429,
                headers={"x-ovid-error": code, "x-ovid-resets-at": resets_at,
                         "retry-after": str(max(1, int(end - self._clock())))},
                provider_specific_fields={"ovid_error": code, "resets_at": resets_at})
        if decision.get("model"):
            data["model"] = decision["model"]
        return data

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        try:
            slo = kwargs.get("standard_logging_object") or {}
            meta = slo.get("metadata") or {}
            uid = meta.get("user_api_key_user_id")
            cost = float(slo.get("response_cost") or kwargs.get("response_cost") or 0)
            if not uid or cost <= 0:
                return
            r = self._redis()
            s, pmap = await self._settings()
            cls, _model = plans.served_class(str(slo.get("model_group") or ""), str(slo.get("model") or ""),
                                             str(slo.get("call_type") or ""), pmap, s)
            pools = await self._pools(r, uid, s)
            start, end = await self._window(r, uid, pools, create=True)
            key = plans.pool_keys(uid)[cls]
            total = float(await r.incrbyfloat(key, cost))
            await r.expire(key, max(1, int(end - self._clock())))
            if pools["kind"] == "split" and cls == "oss" and total >= pools["oss"]:
                await r.sadd(plans.SLOW_PENDING, uid)
        except Exception as e:  # noqa: BLE001 — accounting must never break responses
            print(f"[ovid_pools] accounting skipped: {type(e).__name__}", flush=True)


proxy_handler_instance = OvidPools()
