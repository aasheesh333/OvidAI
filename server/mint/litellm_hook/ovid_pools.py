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

Free-plan token ceilings (product spec §11 / D1) are enforced first, from the
bucketed counters recorded after completed calls: 50M tokens in a rolling 24h
(``free_daily_cap``) and 1.5B in a rolling 30d (``free_monthly_cap``), both
HTTP 429 with ``x-ovid-resets-at``. Paid plans are never token-capped. The
counters live in ``tokens:{uid}:day`` / ``tokens:{uid}:month``.

M1 monitoring gate: when a user's UTC-day spend crosses
``user_daily_spend_alert_usd`` (default $0.50) one queue entry per uid/day is
written to ``alerts:pending:user_spend`` for mint to emit. The env flag
``OVID_PAID_MODELS_KILL_SWITCH`` denies every model call (all upstream models
are paid) with code ``paid_models_disabled`` (HTTP 503); it is checked before
Redis so it cannot fail open. The runtime flag ``config:kill_switch`` (flipped
from mint /admin) denies too, but the env flag is the hard override. Logs never
contain a prompt, email or full uid.
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
user budgets remain the hard backstop). The env kill switch is the exception:
it needs no Redis and always denies.
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


def _usage_tokens(slo: dict, kwargs: dict, response_obj=None) -> int:
    """Total tokens for a completed call from LiteLLM's standard logging object.

    `total_tokens` is used when present (it already includes prompt +
    completion); otherwise the two are added. Anything unparseable counts as 0
    — accounting must never break a response.
    """
    def as_dict(u):
        if isinstance(u, dict):
            return u
        if u is None:
            return None
        d = {k: getattr(u, k, None)
             for k in ("total_tokens", "prompt_tokens", "completion_tokens")}
        return d if any(v is not None for v in d.values()) else None

    usage = as_dict(slo.get("usage")) or as_dict(kwargs.get("usage"))
    if usage is None and response_obj is not None:
        usage = as_dict(getattr(response_obj, "usage", None))
    if not usage:
        return 0
    try:
        if usage.get("total_tokens") is not None:
            return max(0, int(float(usage["total_tokens"])))
        return max(0, int(float(usage.get("prompt_tokens") or 0))
                   + int(float(usage.get("completion_tokens") or 0)))
    except (TypeError, ValueError):
        return 0


class OvidPools(CustomLogger):
    def __init__(self, redis_client=None, clock=time.time, rng=None):
        super().__init__()
        self._r = redis_client
        self._clock = clock
        self._rng = rng or random.Random()
        self._cache: tuple[float, dict | None] = (0.0, None)
        self._kill_logged_at = -1e9

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

    def _log_kill_switch(self) -> None:
        """Log the kill switch at most once a minute (no uid, no prompt)."""
        now = self._clock()
        if now - self._kill_logged_at < 60:
            return
        self._kill_logged_at = now
        print("[ovid_pools] kill switch active: denied model call", flush=True)

    def _raise_denied(self, decision) -> None:
        """Raise the [OI]-shaped rejection for a TokenDecision."""
        code = decision.code or "request_denied"
        headers = {"x-ovid-error": code}
        if decision.retry_at:
            headers["x-ovid-resets-at"] = decision.retry_at
            headers["retry-after"] = str(
                max(1, plans.retry_after_seconds(decision.retry_at, self._clock())))
            message = f"{code}: free-plan token limit reached; resets_at={decision.retry_at}"
        else:
            message = f"{code}: model calls are disabled"
        fields = {"ovid_error": code, "remaining": decision.remaining}
        if decision.retry_at:
            fields["resets_at"] = decision.retry_at
        raise ProxyException(
            message=message, type=code, param="model", code=decision.status,
            headers=headers, provider_specific_fields=fields)

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
        # M1 kill switch: an env flag denies EVERY model call (all upstream
        # models are paid), including master-key/admin calls. It is checked
        # before Redis so a Redis outage cannot fail-open around it. The
        # runtime flag (flipped from mint /admin) is checked next, best effort:
        # if Redis is down the env flag still denies, otherwise we fail open
        # rather than block every request on an unreachable Redis.
        if plans.env_kill_switch_active():
            self._log_kill_switch()
            self._raise_denied(plans.paid_models_disabled())
        try:
            runtime_kill = await self._redis().get(plans.KILL_SWITCH_KEY)
        except Exception as e:  # noqa: BLE001
            runtime_kill = None
            print(f"[ovid_pools] kill switch runtime check skipped: {type(e).__name__}",
                  flush=True)
        if plans.kill_switch_active(runtime_kill):
            self._log_kill_switch()
            self._raise_denied(plans.paid_models_disabled())
        uid = getattr(user_api_key_dict, "user_id", None)
        if not uid:
            return data
        try:
            r = self._redis()
            s = await self._settings()
            pools = await self._pools(r, uid, s)
            # Free-plan token ceilings, decided from completed calls BEFORE
            # this request reaches a model. Paid plans are never token-capped,
            # so their hot path does not read the counter hashes.
            token_keys = plans.token_keys(uid)
            is_free = pools["plan_id"] == "free"
            token_decision = plans.decide_request(
                pools["plan_id"],
                await r.hgetall(token_keys["day"]) if is_free else None,
                await r.hgetall(token_keys["month"]) if is_free else None,
                self._clock())
            win = await self._window(r, uid, pools, create=False)
            spent = await self._spend(r, uid) if win else 0.0
            decision = plans.decide(pools, spent)
        except Exception as e:  # noqa: BLE001 — fail open
            print(f"[ovid_pools] pre-call skipped: {type(e).__name__}", flush=True)
            return data
        if not token_decision.allow:
            self._raise_denied(token_decision)
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

    async def _record_tokens(self, r, uid: str, tokens: int, now: float) -> None:
        """Add this call's tokens to both rolling windows (one hash each)."""
        if tokens <= 0:
            return
        keys = plans.token_keys(uid)
        for name, size, window in (
                ("day", plans.TOKEN_DAY_BUCKET_S, plans.TOKEN_DAY_WINDOW_S),
                ("month", plans.TOKEN_MONTH_BUCKET_S, plans.TOKEN_MONTH_WINDOW_S)):
            field = str(plans.token_bucket(now, size))
            await r.hincrby(keys[name], field, int(tokens))
            await r.expire(keys[name], window + size)

    async def _maybe_alert_user_spend(self, r, uid: str, cost: float, s: dict,
                                      now: float, plan_id: str) -> None:
        """M1: queue one alert per free user per UTC day at the threshold.

        The mint process drains `SPEND_ALERT_PENDING` and sends the operator
        alert (the hook has no alert transport). The queue marker is set once
        per uid/day, so repeated calls above the threshold never re-queue.
        Paid plans are excluded: their spend is bounded by the plan they buy,
        and M1 exists to catch free-tier runaway.
        """
        if plan_id != "free":
            return
        threshold = float(s.get("user_daily_spend_alert_usd") or 0)
        if threshold <= 0:
            return
        day = time.strftime("%Y%m%d", time.gmtime(now))
        spend_key = f"spend:user:{uid}:{day}"
        total = float(await r.incrbyfloat(spend_key, cost))
        await r.expire(spend_key, 2 * 86400)
        if total < threshold:
            return
        if not await r.set(plans.spend_alert_queued_key(uid, day), "1",
                           nx=True, ex=2 * 86400):
            return
        payload = json.dumps({"uid": uid, "day": day, "spend": round(total, 6),
                              "threshold": threshold}, sort_keys=True)
        await r.sadd(plans.SPEND_ALERT_PENDING, payload)

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        try:
            slo = kwargs.get("standard_logging_object") or {}
            meta = slo.get("metadata") or {}
            uid = meta.get("user_api_key_user_id")
            cost = float(slo.get("response_cost") or kwargs.get("response_cost") or 0)
            if not uid:
                return
            r = self._redis()
            now = self._clock()
            # Token accounting is independent of cost: record it even for a
            # zero-cost response so the free-plan ceilings stay exact. A token
            # counter failure must not lose the spend accounting below.
            try:
                await self._record_tokens(r, uid, _usage_tokens(slo, kwargs, response_obj), now)
            except Exception as e:  # noqa: BLE001
                print(f"[ovid_pools] token accounting skipped: {type(e).__name__}", flush=True)
            if cost <= 0:
                return
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
            await self._maybe_alert_user_spend(r, uid, cost, s, now, pools["plan_id"])
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
