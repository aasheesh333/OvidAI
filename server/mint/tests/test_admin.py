"""Admin JSON API: auth, per-user overrides, window resets, ban, lookup, audit."""
import datetime
import json

import pytest

from conftest import ADMIN, standard_models, user_with_keys

AUTH = {"X-Firebase-AppCheck": "x"}

ADMIN_ENDPOINTS = [
    ("GET", "/admin/settings", None),
    ("POST", "/admin/settings", {"free_daily_usd": 9}),
    ("GET", "/admin/plans", None),
    ("POST", "/admin/plans", {"id": "x", "kind": "split"}),
    ("POST", "/admin/plans/pro/disable", None),
    ("GET", "/admin/models", None),
    ("POST", "/admin/set-base-budget", {"daily_usd": 9}),
    ("POST", "/admin/set-tier", {"uid": "u", "tier": "max"}),
    ("POST", "/admin/user/update", {"uid": "u", "daily_usd": 5}),
    ("POST", "/admin/reset-window", {"uid": "u"}),
    ("POST", "/admin/reset-usage", {}),
    ("GET", "/admin/reset-status", None),
    ("POST", "/admin/ban", {"uid": "u"}),
    ("POST", "/admin/unban", {"uid": "u"}),
    ("GET", "/admin/user?q=u", None),
    ("GET", "/admin/audit", None),
    ("GET", "/admin/reapply-status", None),
    ("POST", "/admin/sweep", None),
    ("GET", "/admin/export", None),
]


@pytest.mark.parametrize("method,path,body", ADMIN_ENDPOINTS)
def test_admin_requires_master_key(client, method, path, body):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    settings = mint.get_settings()
    for headers, code in (({}, 401), ({"Authorization": "Bearer nope"}, 403)):
        assert c.request(method, path, json=body, headers=headers).status_code == code
    assert mint.get_settings() == settings
    assert mint.effective_tier("u") == "free" and not mint.rds.get("user:u:banned")
    assert mint.rds.lrange(mint.AUDIT_LIST, 0, -1) == []


def test_admin_page(client):
    c, *_ = client
    r = c.get("/admin")
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    html = r.text
    assert "5 / 10 / 20" not in html
    for needle in ("Plans", "Model classes", "Slow-mode rpm", "Reset window now",
                   "Reset window for ALL users now", "Clear custom pools", "Clear custom free limit",
                   "Models as the app sees them", "Audit log", "monthly backstop"):
        assert needle in html, needle


def test_custom_free_limit_and_clear(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    r = c.post("/admin/user/update", headers=ADMIN, json={"uid": "u", "tier": "starter", "daily_usd": 2})
    assert r.status_code == 200, r.text
    assert r.json()["user"]["tier"] == "3x"
    assert all(fake.keys[t]["max_budget"] == pytest.approx(6) for t in toks.values())
    r = c.post("/admin/user/update", headers=ADMIN, json={"uid": "u", "clear_daily_usd": True})
    assert r.json()["user"]["daily_usd_override"] is None
    assert fake.keys[toks["web"]]["max_budget"] == pytest.approx(0.45)


def test_custom_plan_pools_and_clear(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u", tier="pro")
    r = c.post("/admin/user/update", headers=ADMIN,
               json={"uid": "u", "pools": {"oss_usd": 10, "frontier_usd": 2}})
    assert r.status_code == 200, r.text
    assert fake.keys[toks["android"]]["max_budget"] == pytest.approx(10 * 3 + 2)
    u = c.get("/admin/user", params={"q": "u"}, headers=ADMIN).json()
    assert u["override_pools"] == {"oss_usd": 10.0, "frontier_usd": 2.0}
    assert u["pools_usd"]["oss"] == 10
    c.post("/admin/user/update", headers=ADMIN, json={"uid": "u", "clear_pools": True})
    assert mint.user_pool_override("u") is None
    assert fake.keys[toks["android"]]["max_budget"] == pytest.approx(2 * 3 + 1.5)


@pytest.mark.parametrize("body", [
    {"uid": "u", "tier": "99x"},
    {"uid": "u", "daily_usd": -1},
    {"uid": "u", "pools": {"oss_usd": -1}},
    {"uid": "u", "pools": {"bogus": 1}},
    {"tier": "pro"},
])
def test_user_update_validation(client, body):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    assert c.post("/admin/user/update", headers=ADMIN, json=body).status_code == 400


def test_custom_monthly_backstop(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "monthly_cap_usd": 25})
    assert fake.users["u"]["max_budget"] == 25


def _prime(mint, fake, uid, tier="pro"):
    toks = user_with_keys(mint, fake, uid, tier=tier)
    for t in toks.values():
        fake.keys[t]["spend"] = 0.7
    old = datetime.datetime.now(datetime.timezone.utc).timestamp() - 5 * 3600
    mint.rds.set(f"pool:{uid}:start", str(old))
    mint.rds.set(f"pool:{uid}:spend:oss", "5")
    mint.rds.set(f"pool:{uid}:spend:frontier", "1")
    mint.rds.hset("pools:slow", uid, "9999999999")
    fake.users[uid]["spend"] = 4.0
    return toks, old


def test_reset_window_one_user(client):
    c, mint, fake, _ = client
    toks, old = _prime(mint, fake, "u")
    before = c.post("/usage", headers={"Authorization": "Bearer u", **AUTH}).json()
    r = c.post("/admin/reset-window", headers=ADMIN, json={"uid": "u"})
    assert r.status_code == 200 and r.json()["reset"] == 2
    for t in toks.values():
        assert fake.keys[t]["spend"] == 0
        upd = [u for u in fake.posts("/key/update") if u["key"] == t][-1]
        assert upd["budget_duration"] == "24h" and upd["rpm_limit"] == 240  # clock restarted, slow lifted
    assert fake.users["u"]["spend"] == 0  # paid: user budget is the window budget
    assert mint.rds.get("pool:u:spend:oss") is None and mint.rds.get("pool:u:spend:frontier") is None
    assert float(mint.rds.get("pool:u:start")) > old + 4 * 3600
    assert not mint.in_slow_mode("u")
    after = c.post("/usage", headers={"Authorization": "Bearer u", **AUTH}).json()
    assert after["resets_at"] > before["resets_at"]
    assert after["remaining_fraction"] == 1 and all(not p["slow_mode"] for p in after["pools"])
    entry = c.get("/admin/audit", headers=ADMIN).json()["entries"][0]
    assert (entry["action"], entry["target"]) == ("reset-window", "u")


def test_reset_window_free_keeps_monthly_backstop_unless_asked(client):
    c, mint, fake, _ = client
    _prime(mint, fake, "f", tier="free")
    c.post("/admin/reset-window", headers=ADMIN, json={"uid": "f"})
    assert fake.users["f"]["spend"] == 4.0
    assert all("budget_duration" not in u for u in fake.posts("/user/update"))
    c.post("/admin/reset-window", headers=ADMIN, json={"uid": "f", "reset_month_free": True})
    assert fake.users["f"]["spend"] == 0


def test_reset_window_all_users_background_with_progress(client, monkeypatch):
    c, mint, fake, _ = client
    monkeypatch.setattr(mint, "REAPPLY_SYNC_MAX", 1)
    a, _ = _prime(mint, fake, "a")
    b, _ = _prime(mint, fake, "b", tier="free")
    ran = []
    monkeypatch.setattr(mint.threading, "Thread", lambda target, args=(), daemon=None: type(
        "T", (), {"start": lambda self: ran.append(target(*args))})())
    r = c.post("/admin/reset-window", headers=ADMIN, json={})
    assert r.json()["detail"] == {"mode": "background", "users": 2}
    status = c.get("/admin/reset-status", headers=ADMIN).json()
    assert status["state"] == "done" and status["done"] == status["total"] == 2 and status["keys"] == 4
    assert all(fake.keys[t]["spend"] == 0 for t in list(a.values()) + list(b.values()))
    assert mint.rds.get("pool:a:spend:oss") is None and mint.rds.get("pool:b:spend:oss") is None
    assert mint.rds.hgetall("pools:slow") == {}
    entry = c.get("/admin/audit", headers=ADMIN).json()["entries"][0]
    assert (entry["action"], entry["target"]) == ("reset-window", "ALL")


def test_reset_window_all_users_sync(client):
    c, mint, fake, _ = client
    _prime(mint, fake, "a")
    r = c.post("/admin/reset-window", headers=ADMIN, json={})
    assert r.json()["detail"]["mode"] == "sync" and r.json()["reset"] == 2


def test_legacy_reset_usage_also_resets_monthly(client):
    c, mint, fake, _ = client
    _prime(mint, fake, "f", tier="free")
    r = c.post("/admin/reset-usage", headers=ADMIN, json={"uid": "f"})
    assert r.status_code == 200 and fake.users["f"]["spend"] == 0


def test_ban_blocks_both_keys(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    c.post("/admin/ban", headers=ADMIN, json={"uid": "u"})
    assert all(fake.keys[t]["blocked"] for t in toks.values())
    c.post("/admin/unban", headers=ADMIN, json={"uid": "u"})
    assert not any(fake.keys[t]["blocked"] for t in toks.values())


def test_lookup_by_email_shows_pools_and_app_view(client):
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "u", tier="7x")
    app_body = c.post("/usage", headers={"Authorization": "Bearer u", **AUTH}).json()
    fake.add_log(toks["web"], "prov/deepseek-v4.1-flash", group="auto", spend=0.3, ago_min=0)
    u = c.get("/admin/user", params={"q": "U@Example.com"}, headers=ADMIN).json()
    assert u["uid"] == "u" and u["plan"]["id"] == "pro" and u["tier"] == "7x"
    assert u["spend_by_class_usd"]["oss"] == pytest.approx(0.3)
    assert u["pool_state_usd"]["oss"]["remaining"] == pytest.approx(1.7)
    assert u["today"]["by_model"]["deepseek-v4.1-flash"]["via_auto"] == 1
    assert {p["class"] for p in u["app_view"]["pools"]} == {"oss", "frontier"}
    assert set(u["app_view"]) == set(app_body)
    assert c.get("/admin/user", params={"q": "ghost"}, headers=ADMIN).status_code == 404


def test_admin_models_classes(client):
    c, mint, fake, _ = client
    standard_models(fake)
    j = c.get("/admin/models", headers=ADMIN).json()
    cls = {m["id"]: m["class"] for m in j["models"]}
    assert cls["glm-5.3-flash"] == "oss" and cls["gpt-5.6-luna"] == "frontier" and cls["auto"] == "auto"
    assert next(m for m in j["models"] if m["id"] == "auto")["members"]


def test_audit_log_and_file(client):
    c, mint, fake, tmp = client
    user_with_keys(mint, fake, "u")
    c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 3})
    c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "tier": "7x"})
    c.post("/admin/ban", headers=ADMIN, json={"uid": "u"})
    c.post("/admin/reset-window", headers=ADMIN, json={"uid": "u"})
    entries = c.get("/admin/audit", headers=ADMIN).json()["entries"]
    assert [e["action"] for e in entries] == ["reset-window", "ban", "set-user", "settings"]
    s = entries[-1]
    assert s["before"]["free_daily_usd"] == 0.15 and s["after"]["free_daily_usd"] == 3
    t = entries[-2]
    assert t["before"]["plan"] == "free" and t["after"]["plan"] == "pro" and t["after"]["tier"] == "7x"
    lines = (tmp / "admin-audit.jsonl").read_text().splitlines()
    assert [json.loads(x)["action"] for x in lines] == [e["action"] for e in reversed(entries)]


def test_export(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u", tier="3x")
    mint.rds.set("user:u:pools", json.dumps({"mult": 4}))
    exp = c.get("/admin/export", headers=ADMIN).json()
    assert exp["users"]["u"]["plan"] == "starter" and exp["users"]["u"]["pools_override"] == {"mult": 4}
    assert exp["settings"]["plans"][0]["id"] == "free"
