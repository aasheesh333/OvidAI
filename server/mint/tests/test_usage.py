"""/usage: back-compat fields, pools, window counts incl. auto, per-model remaining."""
import datetime
import json
import re

import pytest

from conftest import ADMIN, standard_models, user_with_keys

AUTH = {"X-Firebase-AppCheck": "x"}

LEGACY_FIELDS = {"tier", "is_paid", "daily_spent_usd", "daily_budget_usd", "daily_remaining_usd",
                 "month_free_spent_usd", "month_free_cap_usd", "requests_today", "budget_window",
                 "remaining_pct", "models"}
NEW_FIELDS = {"plan", "plan_name", "window", "resets_at", "today", "remaining_fraction", "pools"}
DISPLAY_MODEL_FIELDS = {"id", "name", "kind", "priced", "auto", "estimate", "members",
                        "remaining_messages", "remaining_images", "slow_mode"}
LEGACY_MODEL_FIELDS = {"model", "input_cost_per_token", "output_cost_per_token", "remaining_pct"}


def get_usage(c, uid):
    r = c.post("/usage", headers={"Authorization": f"Bearer {uid}", **AUTH})
    assert r.status_code == 200, r.text
    return r.json()


def by_id(body):
    return {m["id"]: m for m in body["models"]}


def pools(body):
    return {p["class"]: p for p in body["pools"]}


def test_usage_keeps_legacy_fields_and_adds_new(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u", tier="3x")
    body = get_usage(c, "u")
    assert LEGACY_FIELDS | NEW_FIELDS <= set(body)
    assert body["tier"] == "3x" and body["plan"] == "starter" and body["plan_name"] == "Go"
    assert body["window"] == body["budget_window"] == "24h"
    for m in body["models"]:
        assert LEGACY_MODEL_FIELDS <= set(m)


def test_window_starts_on_first_use_and_resets_at(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    body = get_usage(c, "u")
    start = float(mint.rds.get("pool:u:start"))
    reset = datetime.datetime.fromisoformat(body["resets_at"].replace("Z", "+00:00"))
    assert abs(reset.timestamp() - (start + 86400)) < 1
    assert all(p["resets_at"] == body["resets_at"] for p in body["pools"])
    assert get_usage(c, "u")["resets_at"] == body["resets_at"]  # stable within the window


def test_expired_window_rolls_over(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u", web=False)
    old = datetime.datetime.now(datetime.timezone.utc).timestamp() - 90000
    mint.rds.set("pool:u:start", str(old))
    mint.rds.set("pool:u:spend", "9")
    mint.rds.hset("pool:u:auto", "glm-5.3-flash", "3")
    fake.add_log(toks["android"], "prov/glm-5.3-flash", ago_min=26 * 60)
    body = get_usage(c, "u")
    assert float(mint.rds.get("pool:u:start")) > old + 80000
    assert mint.rds.get("pool:u:spend") is None and mint.rds.hgetall("pool:u:auto") == {}
    assert body["today"]["requests"] == 0 and body["remaining_fraction"] == 1


def test_today_counts_all_keys_including_auto(client):
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "u")
    fake.add_log(toks["android"], "prov/glm-5.3-flash", group="glm-5.3-flash", pin=1000, pout=200)
    fake.add_log(toks["web"], "prov/minimax-m3", group="auto", pin=500, pout=100)
    fake.add_log(toks["web"], "", group="auto", pin=10, pout=5)
    fake.add_log(toks["android"], "prov/img-1", group="ovid-image", pin=20, pout=0,
                 call_type="aimage_generation")
    fake.add_log(toks["android"], "prov/glm-5.3-flash", status="failure")
    t = get_usage(c, "u")["today"]
    assert (t["requests"], t["input_tokens"], t["output_tokens"], t["images"]) == (4, 1530, 305, 1)
    assert t["auto_requests"] == 2
    assert t["by_model"]["minimax-m3"] == {"requests": 1, "input_tokens": 500, "output_tokens": 100,
                                           "images": 0, "via_auto": 1}
    assert t["by_model"]["auto"]["requests"] == 1


def test_hidden_auto_routing_reported_as_auto(client):
    """Requests the hook rewrote from auto to a member are logged by LiteLLM
    under the member; the hook's per-user tally makes them count as auto."""
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "p", tier="pro")
    get_usage(c, "p")  # opens the window
    for _ in range(3):
        fake.add_log(toks["web"], "prov/glm-5.3-flash", group="glm-5.3-flash", ago_min=0)
    mint.rds.hset("pool:p:auto", "glm-5.3-flash", "2")
    mint.rds.hset("pool:p:auto", "deepseek-v4.1-flash", "9")  # no matching rows yet: ignored
    body = get_usage(c, "p")
    t = body["today"]
    assert t["auto_requests"] == 2 and t["by_model"]["glm-5.3-flash"]["via_auto"] == 2
    assert "auto-oss" not in json.dumps(body)


def test_single_allowance_pool(client):
    c, mint, fake, _ = client
    standard_models(fake)
    mint.rds.set(mint.BASE_BUDGET_KEY, "1")
    toks = user_with_keys(mint, fake, "u")
    fake.add_log(toks["web"], "prov/gemini-3.8-flash", group="gemini-3.8-flash", spend=0.25)
    body = get_usage(c, "u")
    assert body["pools"] == [{"class": "all", "remaining_fraction": 0.75,
                              "resets_at": body["resets_at"], "slow_mode": False}]
    assert body["remaining_fraction"] == 0.75
    m = by_id(body)
    assert m["gemini-3.8-flash"]["remaining_messages"] == int(0.75 / (3e-7 * 2000 + 2.5e-6 * 600) + 1e-9)
    assert not {"class", "pool"} & set(m["glm-5.3-flash"])


def test_exhausted_plan_without_slow_mode(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "p", tier="pro")
    fake.add_log(toks["android"], "prov/glm-5.3-flash", spend=0.15 * 5 + 0.1)
    body = get_usage(c, "p")
    assert body["remaining_fraction"] == 0 and body["pools"][0]["slow_mode"] is False
    assert not mint.in_slow_mode("p")


def test_slow_mode_plan_when_exhausted(client):
    c, mint, fake, _ = client
    standard_models(fake)
    s = mint.get_settings()
    s["plans"] = [dict(p, slow_mode=True) if p["id"] == "pro" else p for p in s["plans"]]
    mint.store_settings(s)
    toks = user_with_keys(mint, fake, "p", tier="7x")
    fake.add_log(toks["android"], "prov/glm-5.3-flash", group="glm-5.3-flash", spend=3.5)
    body = get_usage(c, "p")
    assert body["pools"][0]["slow_mode"] is True and body["remaining_fraction"] == 0
    assert by_id(body)["glm-5.3-flash"]["slow_mode"] is True
    for t in toks.values():
        upd = [u for u in fake.posts("/key/update") if u["key"] == t][-1]
        assert (upd["rpm_limit"], upd["tpm_limit"], upd["max_parallel_requests"]) == (20, 200000, 2)
    assert mint.in_slow_mode("p")


def test_slow_mode_lifted_when_window_ends(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "p", tier="pro")
    mint.rds.hset("pools:slow", "p", "1")  # expired
    out = mint.sweep_slow_mode()
    assert out["lifted"] == 1 and mint.rds.hget("pools:slow", "p") is None
    upd = [u for u in fake.posts("/key/update") if u["key"] == toks["web"]][-1]
    assert upd["rpm_limit"] == 240 and upd["max_parallel_requests"] == 16


def test_sweep_applies_slow_mode_flagged_by_hook(client):
    c, mint, fake, _ = client
    s = mint.get_settings()
    s["plans"] = [dict(p, slow_mode=True) if p["id"] == "max" else p for p in s["plans"]]
    mint.store_settings(s)
    user_with_keys(mint, fake, "p", tier="max")
    mint.rds.set("pool:p:start", str(datetime.datetime.now().timestamp()))
    mint.rds.set("pool:p:spend", "6.5")
    mint.rds.sadd("pools:slow_pending", "p")
    assert mint.sweep_slow_mode()["checked"] == 1
    assert mint.in_slow_mode("p")


def test_hook_counter_counts_when_ahead_of_logs(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    get_usage(c, "u")  # opens the window
    mint.rds.set("pool:u:spend", "0.15")
    assert get_usage(c, "u")["remaining_fraction"] == 0


def test_per_model_remaining_by_price(client):
    c, mint, fake, _ = client
    prices = standard_models(fake)
    user_with_keys(mint, fake, "p", tier="pro")
    m = by_id(get_usage(c, "p"))
    allowance = 0.15 * 5
    cost = {k: i * 2000 + o * 600 for k, (i, o) in prices.items()}
    for k in prices:
        assert m[k]["remaining_messages"] == int(allowance / cost[k] + 1e-9), k
    ordered = sorted(prices, key=cost.get)
    counts = [m[k]["remaining_messages"] for k in ordered]
    assert counts == sorted(counts, reverse=True)
    assert m["big-pro"]["remaining_messages"] < m["deepseek-v4.1-flash"]["remaining_messages"]


def test_auto_estimate_follows_plan_routing(client):
    c, mint, fake, _ = client
    prices = standard_models(fake)
    user_with_keys(mint, fake, "f")                 # free: plain auto
    user_with_keys(mint, fake, "p", tier="pro")     # pro: auto uses auto-oss members
    cost = {k: i * 2000 + o * 600 for k, (i, o) in prices.items()}
    free_auto = by_id(get_usage(c, "f"))["auto"]
    assert free_auto["estimate"] == "conservative" and len(free_auto["members"]) == 6
    assert free_auto["remaining_messages"] == int(0.15 / max(cost.values()) + 1e-9)
    body = get_usage(c, "p")
    pro_auto = by_id(body)["auto"]
    oss = ["deepseek-v4.1-flash", "glm-5.3-flash", "minimax-m3"]
    assert pro_auto["members"] == oss
    assert pro_auto["remaining_messages"] == int(0.15 * 5 / max(cost[x] for x in oss) + 1e-9)
    assert "auto-oss" not in json.dumps(body)


def test_image_model_remaining_images(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "p", tier="max")
    img = by_id(get_usage(c, "p"))["ovid-image"]
    assert img["kind"] == "image" and img["remaining_images"] == int(0.15 * 20 / 0.04 + 1e-9)
    assert "remaining_messages" not in img


def test_image_alias_and_private_backends(client, monkeypatch):
    """server/images wraps _available_models: private backends are hidden and
    the public alias is priced at the dearest private image backend."""
    c, mint, fake, _ = client
    fake.add_model("glm-5.3-flash", "prov/glm-5.3-flash", 2e-7, 8e-7)
    fake.add_model("img-backend-a", "prov/a", per_image=0.02, mode="image_generation")
    fake.add_model("img-backend-b", "prov/b", per_image=0.05, mode="image_generation")
    inner = mint._available_models
    monkeypatch.setattr(mint, "_available_models", lambda: [
        r for r in inner() if not r["model"].startswith("img-backend")] + [{"model": "studio-alias"}])
    mint.rds.set(mint.BASE_BUDGET_KEY, "1")
    user_with_keys(mint, fake, "u")
    m = by_id(get_usage(c, "u"))
    assert set(m) == {"glm-5.3-flash", "studio-alias"}
    assert m["studio-alias"]["kind"] == "image" and m["studio-alias"]["remaining_images"] == 20


def test_image_priced_by_measured_tokens(client):
    c, mint, fake, _ = client
    fake.add_model("tok-image", "prov/tok-image", out=1e-5, mode="image_generation")
    mint.rds.set(mint.BASE_BUDGET_KEY, "1")
    toks = user_with_keys(mint, fake, "u", web=False)
    assert by_id(get_usage(c, "u"))["tok-image"]["remaining_images"] == int(1 / (1e-5 * 1500) + 1e-9)
    fake.add_log(toks["android"], "prov/tok-image", group="tok-image", pout=4000,
                 call_type="aimage_generation", spend=0, ago_min=0)
    assert by_id(get_usage(c, "u"))["tok-image"]["remaining_images"] == int(1 / (1e-5 * 4000) + 1e-9)


def test_unpriced_model(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u")
    m = by_id(get_usage(c, "u"))["mystery"]
    assert m["priced"] is False and m["remaining_messages"] is None


def test_free_remaining_capped_by_monthly_backstop(client):
    c, mint, fake, _ = client
    mint.rds.set(mint.BASE_BUDGET_KEY, "3")
    user_with_keys(mint, fake, "u")
    fake.users["u"]["spend"] = 9.0
    body = get_usage(c, "u")
    assert body["daily_remaining_usd"] == pytest.approx(1.0)
    assert pools(body)["all"]["remaining_fraction"] == pytest.approx(1 / 3, abs=1e-3)
    assert list(pools(body)) == ["all"]


def test_public_plans_endpoint(client):
    c, *_ = client
    plans = c.get("/plans").json()["plans"]
    assert [(p["id"], p["price_usd"], p["aliases"]) for p in plans] == [
        ("free", 0, []), ("starter", 5, ["3x"]), ("pro", 18, ["7x"]), ("max", 99, ["15x"])]


def _walk(v):
    if isinstance(v, dict):
        for k, x in v.items():
            yield k, x
            yield from _walk(x)
    elif isinstance(v, list):
        for x in v:
            yield from _walk(x)


@pytest.mark.parametrize("tier", ["free", "pro"])
def test_no_money_in_display_fields(client, tier):
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "u", tier=tier)
    fake.add_log(toks["web"], "prov/minimax-m3", group="auto", spend=0.02)
    body = get_usage(c, "u")
    display = {k: body[k] for k in NEW_FIELDS}
    display["models"] = [{k: v for k, v in m.items() if k in DISPLAY_MODEL_FIELDS} for m in body["models"]]
    for k, v in _walk(display):
        assert k == "priced" or not re.search(r"usd|cost|price|spend|\$", str(k), re.I), k
        if isinstance(v, str):
            assert "$" not in v
        if isinstance(v, float):
            assert k == "remaining_fraction" and 0 <= v <= 1, k
    for m in body["models"]:
        assert set(m) - DISPLAY_MODEL_FIELDS == LEGACY_MODEL_FIELDS
    assert json.dumps(display).count("$") == 0


def test_usage_cache(client, monkeypatch):
    c, mint, fake, _ = client
    monkeypatch.setattr(mint, "USAGE_CACHE_S", 30)
    toks = user_with_keys(mint, fake, "u", web=False)
    first = get_usage(c, "u")
    fake.add_log(toks["android"], "prov/x", spend=0.1, ago_min=0)
    assert get_usage(c, "u") == first
    mint._drop_usage_cache(["u"])
    assert get_usage(c, "u")["daily_spent_usd"] == pytest.approx(0.1)
