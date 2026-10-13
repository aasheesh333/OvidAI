"""/usage: back-compat fields, window counts incl. auto, per-model remaining."""
import datetime
import re

import pytest

from conftest import standard_models, user_with_keys

AUTH = {"X-Firebase-AppCheck": "x"}

LEGACY_FIELDS = {"tier", "is_paid", "daily_spent_usd", "daily_budget_usd", "daily_remaining_usd",
                 "month_free_spent_usd", "month_free_cap_usd", "requests_today", "budget_window",
                 "remaining_pct", "models"}
DISPLAY_MODEL_FIELDS = {"id", "name", "kind", "priced", "auto", "estimate", "members",
                        "remaining_messages", "remaining_images"}


def get_usage(c, uid):
    r = c.post("/usage", headers={"Authorization": f"Bearer {uid}", **AUTH})
    assert r.status_code == 200, r.text
    return r.json()


def models_by_id(body):
    return {m["id"]: m for m in body["models"]}


def test_usage_keeps_legacy_fields_and_adds_new(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u")
    body = get_usage(c, "u")
    assert LEGACY_FIELDS <= set(body)
    assert {"window", "resets_at", "today", "remaining_fraction"} <= set(body)
    assert body["window"] == body["budget_window"] == "24h"
    assert set(body["today"]) >= {"requests", "input_tokens", "output_tokens", "images"}
    for m in body["models"]:  # app builds today read these
        assert {"model", "input_cost_per_token", "output_cost_per_token", "remaining_pct"} <= set(m)


def test_spend_counts_android_and_web_keys(client):
    """L5: web spend is no longer invisible."""
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    fake.keys[toks["android"]]["spend"] = 0.10
    fake.keys[toks["web"]]["spend"] = 0.15
    body = get_usage(c, "u")
    assert body["daily_spent_usd"] == pytest.approx(0.25)
    assert body["remaining_fraction"] == pytest.approx(0.5)
    assert body["remaining_pct"] == body["remaining_fraction"]


def test_today_counts_all_keys_including_auto(client):
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "u")
    fake.add_log(toks["android"], "prov/glm-5.3-flash", group="glm-5.3-flash", pin=1000, pout=200)
    fake.add_log(toks["web"], "prov/minimax-m3", group="auto", pin=500, pout=100)      # auto → minimax
    fake.add_log(toks["web"], "", group="auto", pin=10, pout=5)                         # auto, unknown member
    fake.add_log(toks["android"], "prov/img-1", group="ovid-image", pin=20, pout=0,
                 call_type="aimage_generation")
    body = get_usage(c, "u")
    t = body["today"]
    assert (t["requests"], t["input_tokens"], t["output_tokens"], t["images"]) == (4, 1530, 305, 1)
    assert t["auto_requests"] == 2
    assert t["by_model"]["minimax-m3"]["via_auto"] == 1
    assert t["by_model"]["auto"]["requests"] == 1
    assert t["by_model"]["ovid-image"]["images"] == 1
    assert body["requests_today"] == 4


def test_auto_attributed_via_deployment_id(client):
    c, mint, fake, _ = client
    fake.add_model("gpt-5.6-luna", "prov/gpt-5.6-luna", 1e-7, 1e-6, mid="manual-luna")
    fake.add_model("auto", "prov/gpt-5.6-luna", 1e-7, 1e-6, mid="auto-luna")
    toks = user_with_keys(mint, fake, "u", web=False)
    fake.add_log(toks["android"], "", group="auto", model_id="auto-luna")
    assert get_usage(c, "u")["today"]["by_model"]["gpt-5.6-luna"]["via_auto"] == 1


def test_today_ignores_rows_before_window_and_failures(client):
    c, mint, fake, _ = client
    standard_models(fake)
    # Window resets in 10h → started 14h ago.
    toks = user_with_keys(mint, fake, "u", web=False, reset_in_h=10)
    fake.add_log(toks["android"], "prov/glm-5.3-flash", ago_min=60)
    fake.add_log(toks["android"], "prov/glm-5.3-flash", ago_min=15 * 60)   # previous window
    fake.add_log(toks["android"], "prov/glm-5.3-flash", status="failure")
    body = get_usage(c, "u")
    assert body["today"]["requests"] == 1
    reset = datetime.datetime.fromisoformat(body["resets_at"].replace("Z", "+00:00"))
    left = reset - datetime.datetime.now(datetime.timezone.utc)
    assert datetime.timedelta(hours=9, minutes=58) < left <= datetime.timedelta(hours=10)
    assert body["resets_at"].endswith("Z")


def test_resets_at_without_keys_is_a_full_window(client):
    c, mint, fake, _ = client
    mint.rds.set("user:p:tier", "3x")
    mint.rds.sadd(mint.ALL_UIDS_SET, "p")
    body = get_usage(c, "p")
    assert body["window"] == "30d"
    reset = datetime.datetime.fromisoformat(body["resets_at"].replace("Z", "+00:00"))
    assert reset - datetime.datetime.now(datetime.timezone.utc) > datetime.timedelta(days=29)


def test_window_switch_shows_in_usage(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "p", tier="7x", duration="30d")
    assert get_usage(c, "p")["window"] == "30d"
    mint.rds.hset(mint.LIMITS_HASH, "paid_window", "24h")
    body = get_usage(c, "p")
    assert body["window"] == "24h"
    assert body["daily_budget_usd"] == pytest.approx(3.5)


def test_remaining_ordered_by_model_price(client):
    c, mint, fake, _ = client
    prices = standard_models(fake)
    mint.rds.set(mint.BASE_BUDGET_KEY, "3")
    user_with_keys(mint, fake, "u")
    m = models_by_id(get_usage(c, "u"))
    remaining = {k: v["remaining_messages"] for k, v in m.items()
                 if v["kind"] == "chat" and not v["auto"] and v["priced"]}
    cost = {k: prices[k][0] * 2000 + prices[k][1] * 600 for k in prices}
    cost["big-pro"] = 5e-6 * 2000 + 2e-5 * 600
    for k, n in remaining.items():
        assert n == int(3 / cost[k] + 1e-9)
    ordered = sorted(remaining, key=lambda k: cost[k])
    values = [remaining[k] for k in ordered]
    assert values == sorted(values, reverse=True)
    assert remaining["big-pro"] < remaining["deepseek-v4.1-flash"]


def test_auto_is_conservative_most_expensive_member(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u")
    m = models_by_id(get_usage(c, "u"))
    auto = m["auto"]
    assert auto["auto"] is True and auto["estimate"] == "conservative" and auto["kind"] == "chat"
    assert len(auto["members"]) == 6 and "big-pro" not in auto["members"]
    member_min = min(m[x]["remaining_messages"] for x in auto["members"])
    assert auto["remaining_messages"] == member_min == m["gemini-3.8-flash"]["remaining_messages"]
    assert body_first_is_auto(get_usage(c, "u"))


def body_first_is_auto(body):
    return body["models"][0]["id"] == "auto"


def test_image_model_remaining_images(client):
    c, mint, fake, _ = client
    standard_models(fake)
    mint.rds.set(mint.BASE_BUDGET_KEY, "1")
    user_with_keys(mint, fake, "u")
    img = models_by_id(get_usage(c, "u"))["ovid-image"]
    assert img["kind"] == "image" and img["remaining_images"] == 25  # $1 / $0.04
    assert "remaining_messages" not in img


def test_image_model_priced_by_tokens_uses_measured_tokens(client):
    c, mint, fake, _ = client
    fake.add_model("tok-image", "prov/tok-image", out=1e-5, mode="image_generation")
    mint.rds.set(mint.BASE_BUDGET_KEY, "1")
    toks = user_with_keys(mint, fake, "u", web=False)
    assert models_by_id(get_usage(c, "u"))["tok-image"]["remaining_images"] == int(1 / (1e-5 * 1500) + 1e-9)
    fake.add_log(toks["android"], "prov/tok-image", group="tok-image", pout=4000,
                 call_type="aimage_generation", spend=0)
    assert models_by_id(get_usage(c, "u"))["tok-image"]["remaining_images"] == int(1 / (1e-5 * 4000) + 1e-9)


def test_unpriced_model(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u")
    m = models_by_id(get_usage(c, "u"))["mystery"]
    assert m["priced"] is False and m["remaining_messages"] is None


def test_estimate_tokens_setting_changes_counts(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u")
    before = models_by_id(get_usage(c, "u"))["glm-5.3-flash"]["remaining_messages"]
    mint.rds.hset(mint.LIMITS_HASH, "est_output_tokens", "6000")
    after = models_by_id(get_usage(c, "u"))["glm-5.3-flash"]["remaining_messages"]
    assert after < before


def test_free_remaining_capped_by_monthly_backstop(client):
    c, mint, fake, _ = client
    mint.rds.set(mint.BASE_BUDGET_KEY, "3")
    user_with_keys(mint, fake, "u")
    fake.users["u"]["spend"] = 9.0  # $1 left of the $10 backstop
    body = get_usage(c, "u")
    assert body["daily_remaining_usd"] == pytest.approx(1.0)
    assert body["remaining_fraction"] == pytest.approx(1 / 3, abs=1e-3)


def _walk(v):
    if isinstance(v, dict):
        for k, x in v.items():
            yield k, x
            yield from _walk(x)
    elif isinstance(v, list):
        for x in v:
            yield from _walk(x)


def test_no_money_in_display_fields(client):
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "u")
    fake.add_log(toks["web"], "prov/minimax-m3", group="auto", spend=0.02)
    body = get_usage(c, "u")
    display = {"window": body["window"], "resets_at": body["resets_at"], "today": body["today"],
               "remaining_fraction": body["remaining_fraction"],
               "models": [{k: v for k, v in m.items() if k in DISPLAY_MODEL_FIELDS} for m in body["models"]]}
    for k, v in _walk(display):
        assert k == "priced" or not re.search(r"usd|cost|price|spend|\$", str(k), re.I), k
        if isinstance(v, str):
            assert "$" not in v
        if isinstance(v, float):
            assert k == "remaining_fraction" and 0 <= v <= 1
    for m in body["models"]:
        extra = set(m) - DISPLAY_MODEL_FIELDS
        assert extra == {"model", "input_cost_per_token", "output_cost_per_token", "remaining_pct"}


def test_usage_cache(client, monkeypatch):
    c, mint, fake, _ = client
    monkeypatch.setattr(mint, "USAGE_CACHE_S", 30)
    toks = user_with_keys(mint, fake, "u", web=False)
    first = get_usage(c, "u")
    fake.keys[toks["android"]]["spend"] = 0.4
    assert get_usage(c, "u") == first
    mint._drop_usage_cache(["u"])
    assert get_usage(c, "u")["daily_spent_usd"] == pytest.approx(0.4)
