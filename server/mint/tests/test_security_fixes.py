"""Regression tests for the mint security hardening batch.

One test per finding: trusted proxies, unresolved-IP fail-closed throttles,
account lifecycle admission, the production test-upgrade refusal, the dedicated
admin key, App Check issuer/allowlist, admin error redaction and billing mount.
"""
import os
import subprocess
import sys
from types import SimpleNamespace

import pytest

from conftest import ADMIN, MASTER, FakeLifecycle, MINT_DIR

AUTH = {"X-Firebase-AppCheck": "x"}


def bearer(uid):
    return {"Authorization": f"Bearer {uid}", **AUTH}


# ── 1. X-Forwarded-For walking + trusted proxies ──
def test_client_ip_uses_rightmost_untrusted_hop_not_spoofed_left_hops(env, monkeypatch):
    mint, _, _ = env
    monkeypatch.setenv("IP_HOP_TRUSTED_PROXIES", "10.0.0.0/8")
    # The rightmost hop before the trusted proxy is the real client.
    assert mint.client_ip("1.1.1.1, 203.0.113.7", "", "10.0.0.5") == "203.0.113.7"
    # Trusted proxy hops are skipped.
    assert mint.client_ip("1.2.3.4, 10.0.0.5", "", "10.0.0.5") == "1.2.3.4"
    # A direct connection: the socket peer beats any supplied header.
    assert mint.client_ip("6.6.6.6, 203.0.113.7", "", "198.51.100.9") == "198.51.100.9"
    # No header at all falls back to the socket peer.
    assert mint.client_ip("", "", "198.51.100.9") == "198.51.100.9"
    # Non-address peers/headers resolve to the shared unresolved bucket.
    assert mint.client_ip("", "", "testclient") == "unknown"


def test_client_ip_trusts_no_proxy_when_list_is_empty(env, monkeypatch):
    mint, _, _ = env
    monkeypatch.setenv("IP_HOP_TRUSTED_PROXIES", "")
    assert mint.client_ip("1.2.3.4", "", "10.0.0.5") == "10.0.0.5"


def test_mint_throttle_cannot_be_bypassed_by_rotating_the_leftmost_hop(client, monkeypatch):
    c, mint, _, _ = client
    monkeypatch.setattr(mint, "MINT_CALLS_PER_IP", 1)
    first = {"Authorization": "Bearer a", **AUTH, "X-Forwarded-For": "1.1.1.1, 203.0.113.7"}
    second = {"Authorization": "Bearer b", **AUTH, "X-Forwarded-For": "2.2.2.2, 203.0.113.7"}
    assert c.post("/mint", headers=first).status_code == 200
    assert c.post("/mint", headers=second).status_code == 429


# ── 2. unresolved IP still throttles (shared bucket) ──
def test_unresolved_ip_uses_the_shared_fail_closed_bucket(client, monkeypatch):
    c, mint, _, _ = client
    monkeypatch.setattr(mint, "MINT_CALLS_PER_IP", 1)
    assert c.post("/mint", headers=bearer("u")).status_code == 200
    assert c.post("/mint", headers=bearer("v")).status_code == 429
    window = int(mint.time.time() // mint.MINT_WINDOW_S)
    assert mint.rds.get(f"mintrate:{mint.UNRESOLVED_IP_BUCKET}:{window}") == "2"


# ── 3. account lifecycle admission before a key/tier mutation ──
def test_mint_requires_a_lifecycle_and_rejects_a_fenced_account(client):
    c, mint, _, _ = client
    mint.ACCOUNT_LIFECYCLE = None
    r = c.post("/mint", headers=bearer("u"))
    assert r.status_code == 503 and "lifecycle" in r.json()["detail"]

    lifecycle = FakeLifecycle()
    lifecycle.blocked.add("fenced")
    mint.ACCOUNT_LIFECYCLE = lifecycle
    r = c.post("/mint", headers=bearer("fenced"))
    assert r.status_code == 403 and r.json()["detail"] == "account_deletion_pending"
    assert lifecycle.accessed == ["fenced"]


def test_upgrade_also_requires_the_lifecycle(client, monkeypatch):
    c, mint, _, _ = client
    monkeypatch.setattr(mint, "ALLOW_TEST_UPGRADE", True)
    lifecycle = FakeLifecycle()
    lifecycle.blocked.add("fenced")
    mint.ACCOUNT_LIFECYCLE = lifecycle
    r = c.post("/upgrade", headers=bearer("fenced"), json={"tier": "pro"})
    assert r.status_code == 403 and r.json()["detail"] == "account_deletion_pending"
    assert mint.rds.get("user:fenced:tier") is None


def test_disabled_or_revoked_claims_are_rejected(client, monkeypatch):
    c, mint, _, _ = client
    monkeypatch.setattr(mint, "verify_google_id_token",
                        lambda token: {"sub": "u", "disabled": True,
                                       "firebase": {"sign_in_provider": "google.com"}})
    r = c.post("/mint", headers=bearer("u"))
    assert r.status_code == 403 and r.json()["detail"] == "account unavailable"


# ── 4. ALLOW_TEST_UPGRADE impossible in production ──
def test_test_upgrade_hatch_is_refused_in_production(env):
    mint, _, _ = env
    for environ in ({"NODE_ENV": "production"}, {"OVID_ENV": "prod"},
                    {"ENVIRONMENT": "production"}):
        with pytest.raises(RuntimeError, match="ALLOW_TEST_UPGRADE"):
            mint.validate_boot_env(True, environ)
    mint.validate_boot_env(True, {"NODE_ENV": "test"})
    mint.validate_boot_env(False, {"NODE_ENV": "production"})


def test_module_boot_raises_on_production_test_upgrade(tmp_path):
    environ = {**os.environ, "FIREBASE_PROJECT_ID": "p", "LITELLM_MASTER_KEY": "m",
               "ALLOW_TEST_UPGRADE": "true", "NODE_ENV": "production",
               "MINT_STATE_DIR": str(tmp_path), "MINT_SPEND_MONITOR": "false",
               "MINT_MOUNT_IMAGES": "false"}
    result = subprocess.run([sys.executable, "-c", "import mint"], cwd=str(MINT_DIR),
                            env=environ, capture_output=True, text=True)
    assert result.returncode != 0
    assert "ALLOW_TEST_UPGRADE" in result.stderr


# ── 5. dedicated admin key takes precedence over the LiteLLM master key ──
def test_dedicated_admin_key_takes_precedence(client, monkeypatch):
    c, mint, _, _ = client
    monkeypatch.setattr(mint, "OVID_ADMIN_KEY", "admin-only-secret")
    assert c.get("/admin/settings", headers={"Authorization": f"Bearer {MASTER}"}).status_code == 403
    assert c.get("/admin/settings",
                 headers={"Authorization": "Bearer admin-only-secret"}).status_code == 200


# ── 6. App Check verifies iss and requires an explicit allowlist ──
def test_appcheck_requires_allowlist_and_verifies_the_issuer(env, monkeypatch):
    mint, _, _ = env
    verify = mint.ORIGINAL_VERIFY_APP_CHECK
    monkeypatch.setattr(mint, "APPCHECK_ENABLED", True)
    monkeypatch.setattr(mint, "APPCHECK_APPS", {})
    with pytest.raises(mint.HTTPException) as raised:
        verify("token")
    assert raised.value.status_code == 503

    monkeypatch.setattr(mint, "APPCHECK_APPS", {"android:com.example": "android"})
    monkeypatch.setenv("FIREBASE_PROJECT_NUMBER", "12345")
    monkeypatch.setattr(mint, "_appcheck_jwk_client", SimpleNamespace(
        get_signing_key_from_jwt=lambda token: SimpleNamespace(key="public-key")))
    seen = {}

    def fake_decode(token, key, **kwargs):
        seen.update(kwargs)
        return {"sub": "android:com.example"}

    monkeypatch.setattr(mint.jwt, "decode", fake_decode)
    assert verify("token") == "android"
    assert seen["issuer"] == "https://firebaseappcheck.googleapis.com/12345"
    assert seen.get("options", {}).get("verify_iss") is not False

    monkeypatch.setattr(mint.jwt, "decode",
                        lambda token, key, **kwargs: {"sub": "android:someone-else"})
    with pytest.raises(mint.HTTPException) as raised:
        verify("token")
    assert raised.value.status_code == 403


# ── 7. admin 400 responses do not echo raw validation text ──
def test_admin_validation_detail_is_stable_and_logged(client, capsys):
    c, _, _, _ = client
    r = c.post("/admin/user/update", headers=ADMIN,
               json={"uid": "u", "pools": {"mult": 100001}})
    assert r.status_code == 400
    assert r.json()["detail"] == "invalid_request"
    assert "mult" not in r.text
    assert "admin validation rejected" in capsys.readouterr().out


# ── 8. billing routes are mounted and fail closed without a Play config ──
def test_billing_routes_are_mounted_on_mint_and_fail_closed(client):
    c, mint, _, _ = client
    assert mint.BILLING_SERVICE is not None
    r = c.post("/billing/verify", headers=bearer("u"),
               json={"purchase_token": "t", "product_id": "ovid_plus_monthly",
                     "package_name": "com.dhanuk.ovidai"})
    assert r.status_code == 503
    assert r.json()["error"]["code"] == "billing_unavailable"
    assert c.post("/billing/rtdn", json={}).status_code == 403
