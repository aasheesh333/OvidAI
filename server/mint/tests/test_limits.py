"""Plans as data, runtime settings, seeding, budgets re-applied to LiteLLM."""
import json
import re

import pytest

from conftest import ADMIN, MINT_DIR, standard_models, user_with_keys

AUTH = {"X-Firebase-AppCheck": "x"}


def usage(c, uid):
    r = c.post("/usage", headers={"Authorization": f"Bearer {uid}", **AUTH})
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.parametrize("path", ["mint.py", "ovid_plans.py", "litellm_hook/ovid_pools.py"])
def test_source_has_no_secret_literals(path):
    src = (MINT_DIR / path).read_text()
    assert not re.search(r"sk-[A-Za-z0-9_-]{12,}", src)
    assert not re.search(r"AIza[0-9A-Za-z_-]{20,}", src)
    assert not re.search(r"\d{8,}:[A-Za-z0-9_-]{30,}", src)  # telegram bot token


def test_new_install_seeds_24h_plans(client):
    c, mint, _, _ = client  # startup ran on an empty Redis
    s = mint.get_settings()
    assert mint.rds.hget(mint.LIMITS_HASH, "plans") is not None
    assert s["free_daily_usd"] == 0.15
    assert [p["id"] for p in s["plans"]] == ["free", "starter", "pro", "max"]
    assert all(p["window_hours"] == 24 for p in s["plans"])
    assert sorted(s["oss_models"]) == sorted(["glm-5.3-flash", "deepseek-v4.1-flash", "minimax-m3"])
    assert (s["slow_rpm"], s["slow_parallel"]) == (20, 2)


def test_existing_install_keeps_live_values_and_30d_paid_windows(env):
    mint, _, _ = env
    mint.rds.set(mint.BASE_BUDGET_KEY, "0.50")
    mint.rds.sadd(mint.ALL_UIDS_SET, "old-user")
    from fastapi.testclient import TestClient
    with TestClient(mint.app):
        s = mint.get_settings()
    assert s["free_daily_usd"] == 0.5
    windows = {p["id"]: p["window_hours"] for p in s["plans"]}
    assert windows == {"free": 24, "starter": 720, "pro": 720, "max": 720}


def test_startup_never_overwrites_settings(env):
    mint, _, _ = env
    mint.rds.set(mint.BASE_BUDGET_KEY, "3")
    custom = [{"id": "free", "name": "Gratis", "kind": "shared", "window_hours": 12, "mult": 1,
               "frontier_share": 0.1, "price_usd": 0, "enabled": True, "aliases": []}]
    mint.rds.hset(mint.LIMITS_HASH, mapping={"plans": json.dumps(custom), "slow_rpm": "7"})
    from fastapi.testclient import TestClient
    for _ in range(2):  # two restarts
        with TestClient(mint.app):
            pass
    s = mint.get_settings()
    assert s["free_daily_usd"] == 3 and s["slow_rpm"] == 7
    assert s["plans"][0]["name"] == "Gratis" and len(s["plans"]) == 1
    assert mint.rds.hget(mint.LIMITS_HASH, "slow_parallel") == "2"  # unset field seeded


@pytest.mark.parametrize("stored,plan", [("3x", "starter"), ("7x", "pro"), ("15x", "max"),
                                         ("starter", "starter"), ("pro", "pro"), ("bogus", "free"),
                                         (None, "free")])
def test_tier_aliases(env, stored, plan):
    mint, _, _ = env
    if stored:
        mint.rds.set("user:u:tier", stored)
    assert mint.effective_tier("u") == plan


def test_shared_plans_free_times_multiplier_with_frontier_share(env):
    mint, _, _ = env
    mint.rds.set(mint.BASE_BUDGET_KEY, "0.2")
    mint.rds.set("user:s:tier", "3x")
    p = mint.pools_for("s")
    assert p["kind"] == "shared" and p["all"] == pytest.approx(0.6) and p["frontier"] == pytest.approx(0.15)
    assert mint.tier_budget("s", "3x") == (pytest.approx(0.6), "24h")
    assert mint.pools_for("f")["all"] == pytest.approx(0.2)


@pytest.mark.parametrize("tier,oss,frontier", [("7x", 2.0, 1.5), ("15x", 3.0, 3.5)])
def test_split_plan_pools_and_key_ceiling(env, tier, oss, frontier):
    mint, _, _ = env
    mint.rds.set("user:p:tier", tier)
    p = mint.pools_for("p")
    assert (p["kind"], p["oss"], p["frontier"]) == ("split", oss, frontier)
    assert mint.tier_budget("p", tier) == (pytest.approx(oss * 3 + frontier), "24h")


def test_window_length_scales_pools(env):
    mint, _, _ = env
    s = mint.get_settings()
    s["plans"] = [dict(p, window_hours=720) if p["id"] == "pro" else p for p in s["plans"]]
    mint.store_settings(s)
    mint.rds.set("user:p:tier", "pro")
    p = mint.pools_for("p")
    assert p["oss"] == pytest.approx(60) and p["frontier"] == pytest.approx(45)
    assert mint.tier_budget("p", "pro")[1] == "30d"


def test_custom_free_limit_scales_shared_not_split(env):
    mint, _, _ = env
    mint.rds.set("user:s:dailyUsd", "1")
    mint.rds.set("user:s:tier", "starter")
    assert mint.pools_for("s")["all"] == pytest.approx(3)
    mint.rds.set("user:s:tier", "pro")
    assert mint.pools_for("s")["oss"] == 2.0


def test_custom_pools_override(env):
    mint, _, _ = env
    mint.rds.set("user:p:tier", "pro")
    mint.rds.set("user:p:pools", json.dumps({"frontier_usd": 10, "window_hours": 48}))
    p = mint.pools_for("p")
    assert p["frontier"] == pytest.approx(20) and p["oss"] == pytest.approx(4) and p["window_hours"] == 48


def test_runtime_settings_take_effect_without_restart(client):
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "u")
    before = usage(c, "u")
    r = c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 3, "slow_rpm": 5})
    assert r.status_code == 200, r.text
    assert r.json()["reapplied"] == {"mode": "sync", "users": 1, "keys": 2, "errors": 0}
    after = usage(c, "u")
    assert after["daily_budget_usd"] == 3 and before["daily_budget_usd"] == 0.15
    glm = lambda b: next(m for m in b["models"] if m["id"] == "glm-5.3-flash")  # noqa: E731
    assert glm(after)["remaining_messages"] > glm(before)["remaining_messages"]
    assert all(fake.keys[t]["max_budget"] == 3 for t in toks.values())
    assert mint.get_settings()["slow_rpm"] == 5


def test_frontier_share_and_classes_take_effect(client):
    c, mint, fake, _ = client
    standard_models(fake)
    user_with_keys(mint, fake, "u")
    s = mint.get_settings()
    s["plans"] = [dict(p, frontier_share=0.5) if p["id"] == "free" else p for p in s["plans"]]
    c.post("/admin/settings", headers=ADMIN, json={"plans": s["plans"], "oss_models": ["big-pro"]})
    body = usage(c, "u")
    big = next(m for m in body["models"] if m["id"] == "big-pro")
    glm = next(m for m in body["models"] if m["id"] == "glm-5.3-flash")
    assert big["class"] == "oss" and big["pool"] == "all"
    assert glm["class"] == "frontier" and glm["pool"] == "frontier"


def test_plan_add_edit_disable(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    r = c.post("/admin/plans", headers=ADMIN, json={
        "id": "team", "name": "Team", "price_usd": 99, "kind": "split", "window_hours": 24,
        "oss_usd": 5, "frontier_usd": 4, "aliases": ["30x"]})
    assert r.status_code == 200, r.text
    assert c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "tier": "team"}).status_code == 200
    assert fake.keys[toks["web"]]["max_budget"] == pytest.approx(5 * 3 + 4)
    assert usage(c, "u")["plan"] == "team"
    c.post("/admin/plans", headers=ADMIN, json={"id": "team", "name": "Team+", "frontier_usd": 6})
    plan = next(p for p in mint.get_settings()["plans"] if p["id"] == "team")
    assert (plan["name"], plan["frontier_usd"], plan["oss_usd"]) == ("Team+", 6, 5)
    assert fake.keys[toks["web"]]["max_budget"] == pytest.approx(5 * 3 + 6)
    assert "team" in [p["id"] for p in c.get("/plans").json()["plans"]]
    assert c.post("/admin/plans/team/disable", headers=ADMIN).status_code == 200
    assert "team" not in [p["id"] for p in c.get("/plans").json()["plans"]]
    assert mint.effective_tier("u") == "team"  # existing users keep a disabled plan
    actions = [e["action"] for e in c.get("/admin/audit", headers=ADMIN).json()["entries"]]
    assert actions[:4] == ["plan-disable", "plan-edit", "set-user", "plan-add"]


def test_upgrade_to_disabled_plan_falls_back_to_free(client, monkeypatch):
    c, mint, fake, _ = client
    monkeypatch.setattr(mint, "ALLOW_TEST_UPGRADE", True)
    user_with_keys(mint, fake, "u")
    c.post("/admin/plans/max/disable", headers=ADMIN)
    r = c.post("/upgrade", headers={"Authorization": "Bearer u", **AUTH}, json={"tier": "15x"})
    assert r.json()["tier"] == "free"
    r = c.post("/upgrade", headers={"Authorization": "Bearer u", **AUTH}, json={"tier": "pro"})
    assert r.json()["tier"] == "7x" and mint.rds.get("user:u:tier") == "7x"  # stored as billing alias


@pytest.mark.parametrize("payload", [
    {"plans": [{"id": "starter", "kind": "shared"}]},                     # no free plan
    {"plans": [{"id": "free", "kind": "shared", "enabled": False}]},
    {"plans": [{"id": "free"}, {"id": "a", "aliases": ["free"]}]},          # duplicate alias
    {"plans": [{"id": "free"}, {"id": "Bad Id"}]},
    {"plans": [{"id": "free", "frontier_share": 1.5}]},
    {"free_daily_usd": -1},
    {"slow_rpm": 0},
    {"oss_models": "glm"},
    {"no_such_setting": 1},
])
def test_invalid_settings_rejected(client, payload):
    c, mint, _, _ = client
    before = mint.get_settings()
    r = c.post("/admin/settings", headers=ADMIN, json=payload)
    assert r.status_code == 400, r.text
    assert mint.get_settings() == before


def test_legacy_set_base_budget_updates_web_keys(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    r = c.post("/admin/set-base-budget", headers=ADMIN, json={"daily_usd": 1.25})
    assert r.status_code == 200 and r.json()["base_daily_usd"] == 1.25
    assert fake.keys[toks["web"]]["max_budget"] == 1.25
    assert fake.keys[toks["android"]]["max_budget"] == 1.25


def test_unchanged_duration_is_not_resent(client):
    """Sending budget_duration restarts LiteLLM's budget clock."""
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "f")
    c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 2})
    updates = fake.posts("/key/update")
    assert updates and all("budget_duration" not in u for u in updates)
    assert all("budget_duration" not in u for u in fake.posts("/user/update"))


def test_settings_mirrored_and_restored_after_redis_loss(client):
    c, mint, _, tmp = client
    c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 3})
    assert json.loads((tmp / "limits.json").read_text())["free_daily_usd"] == 3
    from conftest import make_redis
    mint.rds = make_redis()
    assert mint.restore_settings_if_missing() is True
    assert mint.get_settings()["free_daily_usd"] == 3


def test_mint_existing_key_keeps_budget_clock(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "m", web=False, tier="3x")
    r = c.post("/mint", headers={"Authorization": "Bearer m", **AUTH})
    assert r.status_code == 200, r.text
    assert r.json()["key"] == "sk-m-a" and r.json()["tier"] == "3x"
    upd = [u for u in fake.posts("/key/update") if u["key"] == toks["android"]][-1]
    assert "budget_duration" not in upd and upd["rpm_limit"] == 240
    assert mint.rds.get("email:m@example.com") == "m"


def test_mint_new_key_uses_plan_budget_and_slow_limits(client):
    c, mint, fake, _ = client
    mint.rds.set(mint.BASE_BUDGET_KEY, "2")
    mint.rds.hset("pools:slow", "newbie", "9999999999")
    r = c.post("/mint", headers={"Authorization": "Bearer newbie", **AUTH})
    assert r.status_code == 200, r.text
    gen = fake.posts("/key/generate")[-1]
    assert (gen["max_budget"], gen["budget_duration"]) == (2.0, "24h")
    assert (gen["rpm_limit"], gen["max_parallel_requests"]) == (20, 2)


def test_upgrade_reapplies_both_keys(client, monkeypatch):
    c, mint, fake, _ = client
    monkeypatch.setattr(mint, "ALLOW_TEST_UPGRADE", True)
    toks = user_with_keys(mint, fake, "up")
    r = c.post("/upgrade", headers={"Authorization": "Bearer up", **AUTH}, json={"tier": "max"})
    assert r.status_code == 200 and r.json()["tier"] == "15x"
    for tok in toks.values():
        assert fake.keys[tok]["max_budget"] == pytest.approx(3.0 * 3 + 3.5)
