"""Allowance math, settings validation and re-applying budgets to LiteLLM."""
import json
import re

import pytest

from conftest import ADMIN, MINT_DIR, user_with_keys


def test_source_has_no_secret_literals():
    src = (MINT_DIR / "mint.py").read_text()
    assert not re.search(r"sk-[A-Za-z0-9_-]{12,}", src)
    assert not re.search(r"AIza[0-9A-Za-z_-]{20,}", src)
    assert not re.search(r"\d{8,}:[A-Za-z0-9_-]{30,}", src)  # telegram bot token
    assert 'os.environ["LITELLM_MASTER_KEY"]' in src


def test_defaults_keep_current_behaviour(env):
    mint, _, _ = env
    s = mint.get_settings()
    assert s["free_daily_usd"] == 0.5
    assert s["tier_mult"] == {"free": 1, "3x": 3, "7x": 7, "15x": 15}
    assert s["paid_window"] == "30d"
    assert s["free_monthly_cap_usd"] == 10
    assert (s["est_input_tokens"], s["est_output_tokens"]) == (2000, 600)
    assert mint.tier_budget("u", "free") == (0.5, "24h")
    assert mint.tier_budget("u", "15x") == (0.5 * 15 * 30, "30d")


@pytest.mark.parametrize("tier,mult", [("3x", 3), ("7x", 7), ("15x", 15)])
def test_paid_is_free_times_multiplier(env, tier, mult):
    mint, _, _ = env
    mint.rds.set(mint.BASE_BUDGET_KEY, "3")
    assert mint.tier_budget("u", tier) == (pytest.approx(3 * mult * 30), "30d")


def test_edited_multiplier_is_used(env):
    mint, _, _ = env
    mint.rds.hset(mint.LIMITS_HASH, "mult:7x", "10")
    assert mint.tier_budget("u", "7x")[0] == pytest.approx(0.5 * 10 * 30)


def test_per_user_override_is_free_allowance_scaled_by_plan(env):
    """L2: the override is the user's free allowance; paid = override × mult."""
    mint, _, _ = env
    mint.rds.set("user:u1:dailyUsd", "2")
    assert mint.tier_budget("u1", "free") == (2.0, "24h")
    assert mint.tier_budget("u1", "3x") == (pytest.approx(2 * 3 * 30), "30d")
    assert mint.tier_budget("u2", "3x") == (pytest.approx(0.5 * 3 * 30), "30d")


def test_paid_window_24h(env):
    mint, _, _ = env
    mint.rds.hset(mint.LIMITS_HASH, "paid_window", "24h")
    assert mint.tier_budget("u", "3x") == (1.5, "24h")
    assert mint.tier_budget("u", "free") == (0.5, "24h")


def test_settings_change_reapplies_to_android_and_web_keys(client):
    """Req 1 + L3: a global change hits every key in both namespaces."""
    c, mint, fake, _ = client
    free = user_with_keys(mint, fake, "free1")
    paid = user_with_keys(mint, fake, "paid1", tier="7x", duration="30d")
    r = c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 3})
    assert r.status_code == 200, r.text
    assert r.json()["reapplied"] == {"mode": "sync", "users": 2, "keys": 4, "errors": 0}
    for tok in free.values():
        assert fake.keys[tok]["max_budget"] == 3
    for tok in paid.values():
        assert fake.keys[tok]["max_budget"] == pytest.approx(3 * 7 * 30)
    assert fake.users["paid1"]["max_budget"] == pytest.approx(3 * 7 * 30)
    assert fake.users["free1"]["max_budget"] == 10  # backstop for free users


def test_legacy_set_base_budget_also_updates_web_keys(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u1")
    r = c.post("/admin/set-base-budget", headers=ADMIN, json={"daily_usd": 1.25})
    assert r.status_code == 200 and r.json()["base_daily_usd"] == 1.25
    assert fake.keys[toks["web"]]["max_budget"] == 1.25
    assert fake.keys[toks["android"]]["max_budget"] == 1.25


def test_multiplier_and_window_switch_reapply(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "p", tier="3x", duration="30d")
    r = c.post("/admin/settings", headers=ADMIN,
               json={"tier_mult": {"3x": 4}, "paid_window": "24h"})
    assert r.status_code == 200, r.text
    for tok in toks.values():
        assert fake.keys[tok]["max_budget"] == pytest.approx(0.5 * 4)
        assert fake.keys[tok]["budget_duration"] == "24h"
    assert fake.users["p"]["budget_duration"] == "24h"
    assert mint.get_settings()["tier_mult"]["3x"] == 4


def test_backstop_change_updates_free_user_budget(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "f")
    c.post("/admin/settings", headers=ADMIN, json={"free_monthly_cap_usd": 40})
    assert fake.users["f"]["max_budget"] == 40
    assert mint.free_cap_usd("f") == 40


def test_unchanged_duration_is_not_resent(client):
    """Sending budget_duration restarts LiteLLM's budget clock, so a re-apply
    that keeps the window must only change max_budget."""
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "f")
    c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 2})
    updates = fake.posts("/key/update")
    assert updates and all("budget_duration" not in u for u in updates)
    assert all("budget_duration" not in u for u in fake.posts("/user/update"))


@pytest.mark.parametrize("payload", [
    {"paid_window": "7d"},
    {"free_daily_usd": -1},
    {"tier_mult": {"3x": 0.5}},
    {"tier_mult": {"99x": 2}},
    {"free_monthly_cap_usd": -5},
])
def test_invalid_settings_rejected(client, payload):
    c, mint, _, _ = client
    r = c.post("/admin/settings", headers=ADMIN, json=payload)
    assert r.status_code in (400, 422)
    assert mint.get_settings()["free_daily_usd"] == 0.5


def test_settings_mirrored_and_restored_after_redis_loss(client):
    c, mint, _, tmp = client
    c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 3, "paid_window": "24h"})
    saved = json.loads((tmp / "limits.json").read_text())
    assert saved["free_daily_usd"] == 3
    from conftest import make_redis
    mint.rds = make_redis()  # Redis volume lost
    assert mint.restore_settings_if_missing() is True
    assert mint.get_settings()["free_daily_usd"] == 3
    assert mint.get_paid_window() == "24h"


def test_mint_existing_key_keeps_budget_clock(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "m", web=False)
    r = c.post("/mint", headers={"Authorization": "Bearer m", "X-Firebase-AppCheck": "x"})
    assert r.status_code == 200, r.text
    assert r.json()["key"] == "sk-m-a"
    upd = [u for u in fake.posts("/key/update") if u["key"] == toks["android"]]
    assert upd and "budget_duration" not in upd[-1]
    assert mint.rds.get("email:m@example.com") == "m"


def test_mint_new_key_uses_tier_budget(client):
    c, mint, fake, _ = client
    mint.rds.set(mint.BASE_BUDGET_KEY, "2")
    r = c.post("/mint", headers={"Authorization": "Bearer newbie", "X-Firebase-AppCheck": "x"})
    assert r.status_code == 200, r.text
    gen = fake.posts("/key/generate")[-1]
    assert (gen["max_budget"], gen["budget_duration"]) == (2.0, "24h")


def test_upgrade_reapplies_both_keys(client, monkeypatch):
    c, mint, fake, _ = client
    monkeypatch.setattr(mint, "ALLOW_TEST_UPGRADE", True)
    toks = user_with_keys(mint, fake, "up")
    r = c.post("/upgrade", headers={"Authorization": "Bearer up", "X-Firebase-AppCheck": "x"},
               json={"tier": "15x"})
    assert r.status_code == 200
    for tok in toks.values():
        assert fake.keys[tok]["max_budget"] == pytest.approx(0.5 * 15 * 30)
        assert fake.keys[tok]["budget_duration"] == "30d"
