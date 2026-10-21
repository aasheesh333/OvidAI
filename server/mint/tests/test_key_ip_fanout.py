"""/usage + admin redaction and the per-key IP fan-out contract."""

import hashlib
import json

import pytest

from conftest import ADMIN, standard_models, user_with_keys

AUTH = {"X-Firebase-AppCheck": "x"}
PUBLIC_BASE = "https://cloud.dhanuksoftwares.com/v1"

NETWORKS = ["1.2.3.4", "5.6.7.8", "9.9.9.9", "11.12.13.14",
            "15.16.17.18", "19.20.21.22", "23.24.25.26"]


def usage(c, uid, ip=None):
    headers = {"Authorization": f"Bearer {uid}", **AUTH}
    if ip:
        headers["X-Forwarded-For"] = ip
    return c.post("/usage", headers=headers)


def mint(c, uid, ip=None):
    headers = {"Authorization": f"Bearer {uid}", **AUTH}
    if ip:
        headers["X-Forwarded-For"] = ip
    return c.post("/mint", headers=headers)


def blocked_keys(c):
    r = c.get("/admin/blocked-keys", headers=ADMIN)
    assert r.status_code == 200, r.text
    return r.json()


def unblock(c, ref, reason="reviewed by admin"):
    return c.post("/admin/blocked-keys/unblock", headers=ADMIN,
                  json={"key_ref": ref, "reason": reason})


# ── response redaction ──
def test_usage_and_admin_responses_never_leak_key_material(client):
    c, mint_mod, fake, _ = client
    standard_models(fake)
    toks = user_with_keys(mint_mod, fake, "u", tier="pro")
    fake.add_log(toks["android"], "prov/glm-5.3-flash",
                 group="glm-5.3-flash", spend=0.01, ago_min=0)

    raw_keys = ["sk-u-a", "sk-u-w"]
    key_ids = [toks["android"], toks["web"]]
    hashes = [hashlib.sha256(k.encode()).hexdigest() for k in raw_keys + key_ids]

    responses = [
        usage(c, "u", NETWORKS[0]),
        c.get("/plans"),
        c.get("/admin/user", params={"q": "u"}, headers=ADMIN),
        c.get("/admin/export", headers=ADMIN),
        c.get("/admin/settings", headers=ADMIN),
        c.get("/admin/alerts", headers=ADMIN),
        c.get("/admin/audit", headers=ADMIN),
        c.get("/admin/models", headers=ADMIN),
        c.get("/admin/blocked-keys", headers=ADMIN),
    ]
    for response in responses:
        assert response.status_code == 200, (response.request.url, response.text)
        body = response.text
        for secret in raw_keys + key_ids + hashes:
            assert secret not in body, (response.request.url, secret)
        assert "http://litellm" not in body
        assert PUBLIC_BASE not in body
        assert "cloud.dhanuksoftwares.com" not in body

    # POST /mint is the ONE legitimate key delivery; it is also no-store.
    minted = mint(c, "u", NETWORKS[0])
    assert minted.status_code == 200
    assert minted.json()["key"] == "sk-u-a"
    assert minted.json()["base_url"] == PUBLIC_BASE
    assert minted.headers["cache-control"] == "no-store"
    assert responses[0].headers["cache-control"] == "no-store"


def test_admin_key_detail_never_leaks_the_key(client):
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")
    for i, ip in enumerate(NETWORKS[:6]):
        usage(c, "u", ip)
    ref = mint_mod.key_ip_ref(toks["android"])
    r = c.get(f"/admin/blocked-keys/{ref}", headers=ADMIN)
    assert r.status_code == 200, r.text
    body = r.text
    assert "sk-u-a" not in body and "tok-u-a" not in body
    assert hashlib.sha256(toks["android"].encode()).hexdigest() not in body
    assert PUBLIC_BASE not in body
    assert r.json()["blocked"]["reason"] == "key_ip_fanout"


# ── fan-out block ──
def test_sixth_network_blocks_key_returns_403_and_blocks_litellm(client):
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")

    for ip in NETWORKS[:5]:
        assert usage(c, "u", ip).status_code == 200
    assert not fake.keys[toks["android"]]["blocked"]

    r = usage(c, "u", NETWORKS[5])
    assert r.status_code == 403
    assert r.json()["detail"] == "key_ip_fanout"
    assert r.headers["x-ovid-error"] == "key_ip_fanout"
    assert fake.keys[toks["android"]]["blocked"] is True

    listed = blocked_keys(c)
    assert listed["count"] == 1 and len(listed["blocked"]) == 1
    row = listed["blocked"][0]
    assert row["uid"] == "u" and row["platform"] == "android"
    assert row["reason"] == "key_ip_fanout"
    assert row["key_ref"] == mint_mod.key_ip_ref(toks["android"])
    assert row["distinct_prefixes"] == 6
    assert listed["policy"] == {"limit": 5, "window_seconds": 900,
                                "block_seconds": 86400}


def test_blocked_key_also_returns_403_on_mint_and_usage(client):
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")
    for ip in NETWORKS[:6]:
        usage(c, "u", ip)
    assert fake.keys[toks["android"]]["blocked"]

    for call in (lambda: usage(c, "u", NETWORKS[6]), lambda: mint(c, "u", NETWORKS[6])):
        r = call()
        assert r.status_code == 403
        assert r.json()["detail"] == "key_ip_fanout"


def test_spend_log_networks_also_count_for_fanout(client):
    """A key used directly against the gateway (never re-minting) still fans
    out: the spend logs' requester IPs feed the same guard."""
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")
    assert usage(c, "u", NETWORKS[0]).status_code == 200
    for ip in NETWORKS[1:6]:
        # Inside the live window (the first /usage opened it).
        fake.add_log(toks["android"], "prov/x", ago_min=0, requester_ip=ip)
    r = usage(c, "u", NETWORKS[0])
    assert r.status_code == 403 and r.json()["detail"] == "key_ip_fanout"
    assert fake.keys[toks["android"]]["blocked"] is True
    assert len(mint_mod.rds.lrange(mint_mod.KEY_IP_EMAIL_QUEUE, 0, -1)) == 1


def test_normal_multi_network_mobile_use_is_allowed(client):
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")
    for ip in ["1.2.3.4", "1.2.3.99", "5.6.7.8", "9.9.9.9"]:
        assert usage(c, "u", ip).status_code == 200
    assert not fake.keys[toks["android"]]["blocked"]
    assert blocked_keys(c)["blocked"] == []
    assert mint_mod.rds.lrange(mint_mod.KEY_IP_EMAIL_QUEUE, 0, -1) == []


# ── exactly one email per event ──
def test_exactly_one_email_per_fanout_event(client):
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")
    for ip in NETWORKS[:6]:
        usage(c, "u", ip)
    queue = mint_mod.rds.lrange(mint_mod.KEY_IP_EMAIL_QUEUE, 0, -1)
    assert len(queue) == 1
    event = json.loads(queue[0])
    assert event["reason"] == "key_ip_fanout"
    assert event["distinct_prefixes"] == 6
    assert event["key_ref"] == mint_mod.key_ip_ref(toks["android"])
    assert "sk-u-a" not in queue[0] and "tok-u-a" not in queue[0]
    assert hashlib.sha256(toks["android"].encode()).hexdigest() not in queue[0]

    # Further blocked requests must not enqueue another email.
    for ip in NETWORKS[6:]:
        assert usage(c, "u", ip).status_code == 403
    assert len(mint_mod.rds.lrange(mint_mod.KEY_IP_EMAIL_QUEUE, 0, -1)) == 1

    # The queue drains once through the injectable transport.
    sent = []
    mint_mod.KEY_IP_EMAIL_SENDER = sent.append
    try:
        assert mint_mod.flush_key_ip_emails() == 1
    finally:
        mint_mod.KEY_IP_EMAIL_SENDER = None
    assert len(sent) == 1
    assert sent[0]["key_ref"] == event["key_ref"]
    assert mint_mod.rds.lrange(mint_mod.KEY_IP_EMAIL_QUEUE, 0, -1) == []


def test_unblock_clears_block_unblocks_litellm_and_allows_mint(client):
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")
    for ip in NETWORKS[:6]:
        usage(c, "u", ip)
    ref = mint_mod.key_ip_ref(toks["android"])
    assert fake.keys[toks["android"]]["blocked"]

    r = unblock(c, ref, reason="user was travelling")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ok"] is True and body["upstream_unblocked"] is True
    assert body["uid"] == "u" and body["platform"] == "android"
    assert body["reason"] == "user was travelling"
    assert fake.keys[toks["android"]]["blocked"] is False
    assert blocked_keys(c)["blocked"] == []

    # The reviewed key can mint again and the observation window was reset.
    assert mint(c, "u", NETWORKS[6]).status_code == 200
    assert blocked_keys(c)["blocked"] == []

    # Audit records the reason and the key fingerprint, never the key.
    entries = c.get("/admin/audit", headers=ADMIN).json()["entries"]
    actions = [entry["action"] for entry in entries]
    assert "key-unblock" in actions and "key-ip-fanout" in actions
    unblocked = next(e for e in entries if e["action"] == "key-unblock")
    assert unblocked["after"]["reason"] == "user was travelling"
    assert "sk-u-a" not in json.dumps(entries)


def test_unblock_requires_reason_and_known_key(client):
    c, mint_mod, fake, _ = client
    toks = user_with_keys(mint_mod, fake, "u")
    for ip in NETWORKS[:6]:
        usage(c, "u", ip)
    ref = mint_mod.key_ip_ref(toks["android"])

    assert c.post("/admin/blocked-keys/unblock", headers=ADMIN,
                  json={"key_ref": ref}).status_code == 400
    assert c.post("/admin/blocked-keys/unblock", headers=ADMIN,
                  json={"key_ref": "key_does_not_exist",
                        "reason": "x"}).status_code == 404
    # A failed unblock leaves the block and the LiteLLM key untouched.
    assert fake.keys[toks["android"]]["blocked"] is True
    assert blocked_keys(c)["count"] == 1


def test_blocked_key_admin_routes_require_master_key(client):
    c, mint_mod, fake, _ = client
    user_with_keys(mint_mod, fake, "u")
    for method, path, body in (
        ("GET", "/admin/blocked-keys", None),
        ("GET", "/admin/blocked-keys/key_abc", None),
        ("POST", "/admin/blocked-keys/unblock",
         {"key_ref": "key_abc", "reason": "x"}),
    ):
        assert c.request(method, path, json=body).status_code == 401
        assert c.request(method, path, json=body,
                         headers={"Authorization": "Bearer nope"}).status_code == 403
