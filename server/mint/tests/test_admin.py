"""Admin auth, per-user controls, reset, ban, lookup and the audit log."""
import json

import pytest

from conftest import ADMIN, standard_models, user_with_keys

ADMIN_ENDPOINTS = [
    ("GET", "/admin/settings", None),
    ("POST", "/admin/settings", {"free_daily_usd": 9}),
    ("POST", "/admin/set-base-budget", {"daily_usd": 9}),
    ("POST", "/admin/set-tier", {"uid": "u", "tier": "15x"}),
    ("POST", "/admin/reset-usage", {}),
    ("POST", "/admin/ban", {"uid": "u"}),
    ("POST", "/admin/unban", {"uid": "u"}),
    ("GET", "/admin/user?q=u", None),
    ("GET", "/admin/audit", None),
    ("GET", "/admin/reapply-status", None),
    ("GET", "/admin/export", None),
]


@pytest.mark.parametrize("method,path,body", ADMIN_ENDPOINTS)
def test_admin_requires_master_key(client, method, path, body):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    missing = c.request(method, path, json=body)
    wrong = c.request(method, path, json=body, headers={"Authorization": "Bearer nope"})
    assert missing.status_code == 401
    assert wrong.status_code == 403
    assert mint.get_base_daily() == 0.5
    assert mint.effective_tier("u") == "free"
    assert not mint.rds.get("user:u:banned")
    assert mint.rds.lrange(mint.AUDIT_LIST, 0, -1) == []


def test_admin_page_copy_and_headers(client):
    c, *_ = client
    r = c.get("/admin")
    assert r.status_code == 200
    assert r.headers["cache-control"] == "no-store"
    html = r.text
    assert "5 / 10 / 20" not in html  # L6
    for needle in ("3x plan multiplier", "7x plan multiplier", "15x plan multiplier",
                   "Paid window", "monthly backstop", "Audit log", "Models as the app sees them"):
        assert needle in html


def test_set_user_override_and_clear(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    r = c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "tier": "3x", "daily_usd": 2})
    assert r.status_code == 200, r.text
    for tok in toks.values():
        assert fake.keys[tok]["max_budget"] == pytest.approx(2 * 3 * 30)
        assert fake.keys[tok]["budget_duration"] == "30d"
    r = c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "clear_daily_usd": True})
    assert r.json()["user"]["daily_usd_override"] is None
    assert fake.keys[toks["web"]]["max_budget"] == pytest.approx(0.5 * 3 * 30)


def test_set_user_monthly_cap_override(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "monthly_cap_usd": 25})
    assert fake.users["u"]["max_budget"] == 25


def test_set_tier_rejects_unknown_tier_and_negative(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    assert c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "tier": "99x"}).status_code == 400
    assert c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "daily_usd": -1}).status_code == 400


def test_reset_user_zeroes_both_keys_and_monthly_spend(client):
    """L3 + L4: web key reset too; the monthly backstop spend is really reset."""
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    for tok in toks.values():
        fake.keys[tok]["spend"] = 0.4
    fake.users["u"]["spend"] = 7.0
    r = c.post("/admin/reset-usage", headers=ADMIN, json={"uid": "u"})
    assert r.status_code == 200 and r.json()["reset"] == 2
    assert all(fake.keys[t]["spend"] == 0 for t in toks.values())
    assert fake.users["u"]["spend"] == 0


def test_reset_all(client):
    c, mint, fake, _ = client
    a = user_with_keys(mint, fake, "a")
    b = user_with_keys(mint, fake, "b", web=False)
    for t in list(a.values()) + list(b.values()):
        fake.keys[t]["spend"] = 1
    r = c.post("/admin/reset-usage", headers=ADMIN, json={})
    assert r.json()["detail"]["users"] == 2 and r.json()["reset"] == 3


def test_ban_blocks_both_keys(client):
    c, mint, fake, _ = client
    toks = user_with_keys(mint, fake, "u")
    c.post("/admin/ban", headers=ADMIN, json={"uid": "u"})
    assert all(fake.keys[t]["blocked"] for t in toks.values())
    assert mint.rds.get("user:u:banned") == "admin"
    c.post("/admin/unban", headers=ADMIN, json={"uid": "u"})
    assert not any(fake.keys[t]["blocked"] for t in toks.values())
    assert mint.rds.get("user:u:banned") is None


def test_lookup_by_uid_and_email_matches_app_view(client):
    c, mint, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint, fake, "u")
    fake.keys[toks["web"]]["spend"] = 0.2
    fake.add_log(toks["web"], "prov/deepseek-v4.1-flash", group="auto", pin=300, pout=30)
    app_body = c.post("/usage", headers={"Authorization": "Bearer u", "X-Firebase-AppCheck": "x"}).json()
    r = c.get("/admin/user", params={"q": "U@Example.com"}, headers=ADMIN)
    assert r.status_code == 200, r.text
    u = r.json()
    assert u["uid"] == "u" and u["email"] == "u@example.com"
    assert u["today"]["requests"] == 1 and u["today"]["spend_usd"] == pytest.approx(0.2)
    assert u["today"]["by_model"]["deepseek-v4.1-flash"]["via_auto"] == 1
    assert u["multiplier"] == 1 and u["allowance_usd"] == 0.5
    assert {k["platform"] for k in u["keys"]} == {"android", "web"}
    strip = lambda b: {k: v for k, v in b.items() if k != "resets_at"}  # noqa: E731
    assert strip(u["app_view"]) == strip(app_body)
    assert c.get("/admin/user", params={"q": "u"}, headers=ADMIN).json()["uid"] == "u"


def test_lookup_unknown_user_404(client):
    c, *_ = client
    assert c.get("/admin/user", params={"q": "ghost"}, headers=ADMIN).status_code == 404
    assert c.get("/admin/user", params={"q": "ghost@x.com"}, headers=ADMIN).status_code == 404


def test_audit_log_records_every_change(client):
    c, mint, fake, tmp = client
    user_with_keys(mint, fake, "u")
    c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 3})
    c.post("/admin/set-tier", headers=ADMIN, json={"uid": "u", "tier": "7x"})
    c.post("/admin/ban", headers=ADMIN, json={"uid": "u"})
    c.post("/admin/unban", headers=ADMIN, json={"uid": "u"})
    c.post("/admin/reset-usage", headers=ADMIN, json={"uid": "u"})
    c.post("/admin/set-base-budget", headers=ADMIN, json={"daily_usd": 1})
    entries = c.get("/admin/audit", headers=ADMIN).json()["entries"]
    assert [e["action"] for e in entries] == [
        "set-base-budget", "reset-usage", "unban", "ban", "set-user", "settings"]
    settings = entries[-1]
    assert settings["before"]["free_daily_usd"] == 0.5 and settings["after"]["free_daily_usd"] == 3
    assert settings["result"]["keys"] == 2
    tier = entries[-2]
    assert tier["target"] == "u" and tier["before"]["tier"] == "free" and tier["after"]["tier"] == "7x"
    assert all(e["actor"] == "master-key" and e["ts"].endswith("Z") for e in entries)
    lines = (tmp / "admin-audit.jsonl").read_text().splitlines()
    assert [json.loads(x)["action"] for x in lines] == [e["action"] for e in reversed(entries)]


def test_admin_settings_get_and_export(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u", tier="3x")
    mint.remember_email("u", "U@x.com")
    s = c.get("/admin/settings", headers=ADMIN).json()
    assert s["settings"]["paid_window"] == "30d" and s["users"] == 1
    exp = c.get("/admin/export", headers=ADMIN).json()
    assert exp["users"]["u"]["tier"] == "3x" and exp["users"]["u"]["email"] == "u@x.com"


def test_large_reapply_runs_in_background(client, monkeypatch):
    c, mint, fake, _ = client
    monkeypatch.setattr(mint, "REAPPLY_SYNC_MAX", 1)
    user_with_keys(mint, fake, "a")
    user_with_keys(mint, fake, "b")
    started = []
    monkeypatch.setattr(mint.threading, "Thread",
                        lambda target, args=(), daemon=None: type("T", (), {
                            "start": lambda self: started.append(target(*args))})())
    r = c.post("/admin/settings", headers=ADMIN, json={"free_daily_usd": 2})
    assert r.json()["reapplied"] == {"mode": "background", "users": 2}
    assert started and started[0]["keys"] == 4
    assert json.loads(mint.rds.get(mint.REAPPLY_STATUS_KEY))["state"] == "done"
