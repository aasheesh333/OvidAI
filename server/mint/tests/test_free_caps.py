"""Free-plan token ceilings (50M/24h, 1.5B/30d) and the M1 monitoring gate.

Covers the typed pre-call decision, both rolling caps, their reset boundary,
paid-tier isolation, the once-per-user/day spend alert, and the env kill switch.
"""
import asyncio
import json
import random
import sys
import time
import types

import pytest

from conftest import ADMIN, MINT_DIR, AsyncRedis, MemoryRedis, standard_models, user_with_keys

sys.path.insert(0, str(MINT_DIR / "litellm_hook"))
sys.path.insert(0, str(MINT_DIR))
import ovid_plans as plans  # noqa: E402
import ovid_pools  # noqa: E402

NOW = 1_800_000_000.0
AUTH = {"X-Firebase-AppCheck": "x"}
MODEL = "glm-5.3-flash"


class Clock:
    def __init__(self, t=NOW):
        self.t = t

    def __call__(self):
        return self.t


def make_hook(threshold=0.5, r=None, clock=None):
    """Hook over a fake Redis with a $1/day USD allowance (so the token caps,
    not the USD allowance, are what the tests exercise)."""
    r = r or MemoryRedis()
    s = plans.parse_settings({}, "1.0")
    s["user_daily_spend_alert_usd"] = threshold
    base, fields = plans.serialize_settings(s)
    r.set(plans.BASE_BUDGET_KEY, base)
    r.hset(plans.LIMITS_HASH, mapping=fields)
    clock = clock or Clock()
    hook = ovid_pools.OvidPools(redis_client=AsyncRedis(r), clock=clock,
                                rng=random.Random(1))
    return hook, r, clock


def run(coro):
    return asyncio.run(coro)


def key(uid):
    return types.SimpleNamespace(user_id=uid)


def pre(h, uid, model=MODEL):
    return run(h.async_pre_call_hook(key(uid), None, {"model": model}, "acompletion"))


def success(h, uid, cost=0.0, tokens=0, group=MODEL, auto=False):
    kwargs = {
        "standard_logging_object": {
            "metadata": {"user_api_key_user_id": uid},
            "response_cost": cost,
            "model_group": group,
            "model": f"prov/{group}",
            "call_type": "acompletion",
            "usage": {"total_tokens": tokens, "prompt_tokens": tokens,
                      "completion_tokens": 0},
        },
        "litellm_params": {"metadata": {"ovid_auto": True} if auto else {}},
    }
    run(h.async_log_success_event(kwargs, None, None, None))


def rejected(h, uid, model=MODEL):
    with pytest.raises(ovid_pools.ProxyException) as e:
        pre(h, uid, model)
    return e.value


def day_bucket(now, tokens):
    return {str(plans.token_bucket(now, plans.TOKEN_DAY_BUCKET_S)): str(tokens)}


def month_bucket(now, tokens):
    return {str(plans.token_bucket(now, plans.TOKEN_MONTH_BUCKET_S)): str(tokens)}


# ── typed decision (pure) ──
def test_decision_is_typed_and_allows_under_cap():
    d = plans.decide_tokens("free", {}, {}, NOW)
    assert d.allow is True
    assert d.reason is None and d.retry_at is None and d.code is None
    assert d.status == 200
    assert d.remaining == {"daily": plans.FREE_DAILY_TOKENS,
                           "monthly": plans.FREE_MONTHLY_TOKENS}
    assert d.as_dict()["allow"] is True


def test_decision_denies_exactly_at_the_daily_cap():
    d = plans.decide_tokens("free", day_bucket(NOW, plans.FREE_DAILY_TOKENS),
                            month_bucket(NOW, plans.FREE_DAILY_TOKENS), NOW)
    assert d.allow is False
    assert (d.reason, d.code, d.status) == ("daily_token_cap", "free_daily_cap", 429)
    assert d.remaining["daily"] == 0
    assert d.retry_at == plans.iso_utc(NOW + plans.TOKEN_DAY_BUCKET_S + plans.TOKEN_DAY_WINDOW_S)


def test_decision_denies_at_the_monthly_cap_only_when_day_is_clear():
    d = plans.decide_tokens("free", {}, month_bucket(NOW, plans.FREE_MONTHLY_TOKENS), NOW)
    assert d.allow is False
    assert (d.reason, d.code, d.status) == ("monthly_token_cap", "free_monthly_cap", 429)
    assert d.remaining["monthly"] == 0
    assert d.remaining["daily"] == plans.FREE_DAILY_TOKENS


def test_decision_ignores_token_caps_for_paid_plans():
    d = plans.decide_tokens("starter", day_bucket(NOW, 10 ** 12),
                            month_bucket(NOW, 10 ** 12), NOW)
    assert d.allow is True
    assert d.remaining == {"daily": None, "monthly": None}


def test_decide_request_kill_switch_is_a_typed_denial():
    d = plans.decide_request("free", {}, {}, NOW, kill_switch=True)
    assert (d.allow, d.reason, d.code, d.status) == (
        False, "paid_models_disabled", "paid_models_disabled", 503)
    assert d.retry_at is None


# ── hook enforcement ──
def test_usage_tokens_reads_dicts_objects_and_bad_values():
    assert ovid_pools._usage_tokens(
        {"usage": {"total_tokens": 123, "prompt_tokens": 100, "completion_tokens": 23}}, {}) == 123
    assert ovid_pools._usage_tokens(
        {"usage": {"prompt_tokens": 10, "completion_tokens": 5}}, {}) == 15

    class U:
        total_tokens = 77

    assert ovid_pools._usage_tokens({}, {}, types.SimpleNamespace(usage=U())) == 77
    assert ovid_pools._usage_tokens({"usage": {"total_tokens": "nope"}}, {}) == 0
    assert ovid_pools._usage_tokens({}, {}) == 0


def test_under_cap_allows():
    h, _, _ = make_hook()
    success(h, "u", tokens=plans.FREE_DAILY_TOKENS - 1)
    assert pre(h, "u")["model"] == MODEL


def test_daily_cap_hit_returns_429_with_code_and_reset():
    h, r, _ = make_hook()
    success(h, "u", tokens=plans.FREE_DAILY_TOKENS)
    err = rejected(h, "u")
    assert (err.type, err.code) == ("free_daily_cap", "429")
    expected = plans.iso_utc(NOW + plans.TOKEN_DAY_BUCKET_S + plans.TOKEN_DAY_WINDOW_S)
    assert err.headers["x-ovid-error"] == "free_daily_cap"
    assert err.headers["x-ovid-resets-at"] == expected
    assert err.headers["retry-after"] == str(plans.TOKEN_DAY_BUCKET_S + plans.TOKEN_DAY_WINDOW_S)
    assert err.provider_specific_fields["ovid_error"] == "free_daily_cap"
    assert err.provider_specific_fields["remaining"]["daily"] == 0
    # The token ceiling is per user: another user is unaffected.
    assert pre(h, "other")["model"] == MODEL


def test_monthly_cap_hit_after_the_day_window_clears():
    h, _, clock = make_hook()
    success(h, "u", tokens=plans.FREE_MONTHLY_TOKENS)
    # Past the 24h window (plus the conservative bucket) but inside 30 days.
    clock.t = NOW + plans.TOKEN_DAY_WINDOW_S + plans.TOKEN_DAY_BUCKET_S + 1
    err = rejected(h, "u")
    assert (err.type, err.code) == ("free_monthly_cap", "429")
    expected = plans.iso_utc(
        NOW + plans.TOKEN_MONTH_BUCKET_S + plans.TOKEN_MONTH_WINDOW_S)
    assert err.headers["x-ovid-resets-at"] == expected
    assert err.provider_specific_fields["remaining"]["monthly"] == 0


def test_daily_reset_boundary_allows_again():
    h, _, clock = make_hook()
    success(h, "u", tokens=plans.FREE_DAILY_TOKENS)
    assert rejected(h, "u").type == "free_daily_cap"
    clock.t = NOW + plans.TOKEN_DAY_BUCKET_S + plans.TOKEN_DAY_WINDOW_S + 1
    assert pre(h, "u")["model"] == MODEL


def test_monthly_reset_boundary_allows_again():
    h, _, clock = make_hook()
    success(h, "u", tokens=plans.FREE_MONTHLY_TOKENS)
    clock.t = NOW + plans.TOKEN_DAY_WINDOW_S + plans.TOKEN_DAY_BUCKET_S + 1
    assert rejected(h, "u").type == "free_monthly_cap"
    clock.t = NOW + plans.TOKEN_MONTH_BUCKET_S + plans.TOKEN_MONTH_WINDOW_S + 1
    assert pre(h, "u")["model"] == MODEL


def test_paid_tier_is_not_token_capped():
    h, r, _ = make_hook()
    r.set("user:p:tier", "3x")
    success(h, "p", tokens=plans.FREE_MONTHLY_TOKENS + 1)
    assert pre(h, "p")["model"] == MODEL


# ── M1: per-user daily spend alert ──
def test_spend_alert_queues_once_per_user_per_day(env):
    mint, _, _ = env
    r = MemoryRedis()
    h, _, clock = make_hook(threshold=0.5, r=r)

    success(h, "user-alert-123", cost=0.30)
    assert r.scard(plans.SPEND_ALERT_PENDING) == 0  # under the threshold
    success(h, "user-alert-123", cost=0.30)
    assert r.scard(plans.SPEND_ALERT_PENDING) == 1
    success(h, "user-alert-123", cost=5.00)         # same day, must not re-queue
    success(h, "user-alert-123", cost=5.00)
    assert r.scard(plans.SPEND_ALERT_PENDING) == 1

    payload = json.loads(next(iter(r.smembers(plans.SPEND_ALERT_PENDING))))
    assert payload["uid"] == "user-alert-123" and payload["spend"] == pytest.approx(0.6)

    # A second user gets their own alert on the same day.
    success(h, "second-user", cost=0.60)
    assert r.scard(plans.SPEND_ALERT_PENDING) == 2

    # Paid users are not part of M1 (their spend is bounded by their plan).
    r.set("user:paid-alert:tier", "3x")
    success(h, "paid-alert", cost=5.00)
    assert r.scard(plans.SPEND_ALERT_PENDING) == 2

    # Mint drains the queue exactly once, even if called repeatedly.
    mint.rds = r
    delivered = []
    mint.ALERT_SINK = types.SimpleNamespace(
        webhook_url="", deliver=lambda p: delivered.append(p) or "log")
    assert mint.flush_user_spend_alerts() == 2
    assert mint.flush_user_spend_alerts() == 0
    assert [p["kind"] for p in delivered] == ["user_spend", "user_spend"]
    for payload in delivered:
        blob = json.dumps(payload)
        assert "@" not in blob and "prompt" not in blob
        assert payload["uid_hash"] != "user-alert-123"
        assert payload["spend_usd"] >= 0.6 and payload["cap_usd"] == 0.5
        assert payload["window"].startswith("utc_day:")


def test_spend_alert_resets_on_the_next_utc_day():
    h, r, clock = make_hook(threshold=0.5)
    success(h, "u", cost=0.6)
    assert r.scard(plans.SPEND_ALERT_PENDING) == 1
    clock.t += 86400
    success(h, "u", cost=0.6)
    assert r.scard(plans.SPEND_ALERT_PENDING) == 2


def test_spend_alert_threshold_is_configurable(client):
    c, mint, _, _ = client
    assert mint.get_settings()["user_daily_spend_alert_usd"] == 0.5
    r = c.post("/admin/settings", headers=ADMIN, json={"user_daily_spend_alert_usd": 1.25})
    assert r.status_code == 200, r.text
    assert mint.get_settings()["user_daily_spend_alert_usd"] == 1.25
    assert c.post("/admin/settings", headers=ADMIN,
                  json={"user_daily_spend_alert_usd": -1}).status_code == 400


# ── M1: global kill switch ──
def test_kill_switch_denies_all_models_with_distinct_code(monkeypatch, capsys):
    h, r, _ = make_hook()
    r.set("user:p:tier", "3x")
    monkeypatch.setenv(plans.KILL_SWITCH_ENV, "true")
    for uid in ("free-user", "paid-user"):
        err = rejected(h, uid)
        assert (err.type, err.code) == ("paid_models_disabled", "503")
        assert err.headers["x-ovid-error"] == "paid_models_disabled"
        assert "x-ovid-resets-at" not in err.headers
    out = capsys.readouterr().out
    assert "kill switch active" in out
    assert "free-user" not in out and "paid-user" not in out  # no uid in logs


def test_kill_switch_does_not_fail_open_when_redis_is_down(monkeypatch):
    r = MemoryRedis()
    h = ovid_pools.OvidPools(redis_client=AsyncRedis(r, fail=True), clock=Clock())
    monkeypatch.setenv(plans.KILL_SWITCH_ENV, "1")
    assert rejected(h, "u").type == "paid_models_disabled"


def test_kill_switch_also_denies_master_key_calls(monkeypatch):
    h, _, _ = make_hook()
    monkeypatch.setenv(plans.KILL_SWITCH_ENV, "true")
    with pytest.raises(ovid_pools.ProxyException) as e:
        run(h.async_pre_call_hook(key(None), None, {"model": MODEL}, "acompletion"))
    assert e.value.type == "paid_models_disabled"


def test_kill_switch_off_by_default(monkeypatch):
    monkeypatch.delenv(plans.KILL_SWITCH_ENV, raising=False)
    h, _, _ = make_hook()
    assert pre(h, "u")["model"] == MODEL


def test_runtime_kill_switch_denies_and_logs(monkeypatch, capsys):
    """The /admin flip (Redis flag) denies without an env change, and logs."""
    monkeypatch.delenv(plans.KILL_SWITCH_ENV, raising=False)
    h, r, _ = make_hook()
    r.set(plans.KILL_SWITCH_KEY, "1")
    err = rejected(h, "free-user")
    assert (err.type, err.code) == ("paid_models_disabled", "503")
    assert "kill switch active" in capsys.readouterr().out

    r.delete(plans.KILL_SWITCH_KEY)
    assert pre(h, "u")["model"] == MODEL


def test_runtime_flag_cannot_override_the_env_flag(monkeypatch):
    monkeypatch.setenv(plans.KILL_SWITCH_ENV, "true")
    h, r, _ = make_hook()
    r.delete(plans.KILL_SWITCH_KEY)          # runtime off, env still on
    assert rejected(h, "u").type == "paid_models_disabled"


# ── mint API surface ──
def _seed_tokens(mint, uid, day=0, month=0):
    keys = plans.token_keys(uid)
    now = time.time()
    if day:
        mint.rds.hset(keys["day"], str(plans.token_bucket(now, plans.TOKEN_DAY_BUCKET_S)), str(day))
    if month:
        mint.rds.hset(keys["month"], str(plans.token_bucket(now, plans.TOKEN_MONTH_BUCKET_S)), str(month))


def test_mint_returns_429_with_machine_code_and_reset(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    _seed_tokens(mint, "u", day=plans.FREE_DAILY_TOKENS)
    r = c.post("/mint", headers={"Authorization": "Bearer u", **AUTH})
    assert r.status_code == 429, r.text
    detail = r.json()["detail"]
    assert detail["error"] == "free_daily_cap" and detail["reason"] == "daily_token_cap"
    assert detail["remaining"]["daily"] == 0
    assert r.headers["x-ovid-error"] == "free_daily_cap"
    assert r.headers["x-ovid-resets-at"] == detail["resets_at"]
    assert int(r.headers["retry-after"]) > 0


def test_mint_returns_429_for_the_monthly_cap(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    _seed_tokens(mint, "u", month=plans.FREE_MONTHLY_TOKENS)
    r = c.post("/mint", headers={"Authorization": "Bearer u", **AUTH})
    assert r.status_code == 429, r.text
    assert r.json()["detail"]["error"] == "free_monthly_cap"


def test_mint_allows_paid_user_past_the_token_caps(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "p", tier="3x")
    _seed_tokens(mint, "p", day=plans.FREE_MONTHLY_TOKENS + 1,
                 month=plans.FREE_MONTHLY_TOKENS + 1)
    r = c.post("/mint", headers={"Authorization": "Bearer p", **AUTH})
    assert r.status_code == 200, r.text


def test_mint_kill_switch_returns_distinct_code(client, monkeypatch):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    monkeypatch.setenv(plans.KILL_SWITCH_ENV, "true")
    r = c.post("/mint", headers={"Authorization": "Bearer u", **AUTH})
    assert r.status_code == 503, r.text
    assert r.json()["detail"]["error"] == "paid_models_disabled"
    assert r.headers["x-ovid-error"] == "paid_models_disabled"


def test_usage_reports_free_token_windows(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u")
    _seed_tokens(mint, "u", day=10_000_000, month=20_000_000)
    body = c.post("/usage", headers={"Authorization": "Bearer u", **AUTH}).json()
    assert body["tokens"]["daily"] == {
        "cap": plans.FREE_DAILY_TOKENS,
        "remaining": plans.FREE_DAILY_TOKENS - 10_000_000,
        "used": 10_000_000,
    }
    assert body["tokens"]["monthly"]["used"] == 20_000_000


def test_usage_has_no_token_windows_for_paid(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "p", tier="pro")
    body = c.post("/usage", headers={"Authorization": "Bearer p", **AUTH}).json()
    assert body["tokens"] is None
