"""M1 monitoring gate operations: alert sink, alert history, kill-switch admin.

The gate must be *operable*, not just computed: every alert has one documented
JSON payload, webhook failures fall back to the log, and an operator can read
recent alerts and flip the kill switch (with an audit trail) at runtime.
"""
import hashlib
import json
import sys

import pytest

from conftest import ADMIN, MINT_DIR, user_with_keys

sys.path.insert(0, str(MINT_DIR))
import m1_alerts  # noqa: E402
import ovid_plans as plans  # noqa: E402

AUTH = {"X-Firebase-AppCheck": "x"}
NOW = 1_800_000_000.0


class RecordingSink:
    def __init__(self, delivery="webhook"):
        self.webhook_url = "https://alerts.example/hook"
        self.delivery = delivery
        self.payloads = []

    def deliver(self, payload):
        self.payloads.append(payload)
        return self.delivery


def queued(uid, day="20261021", spend=0.75, threshold=0.5):
    return json.dumps({"uid": uid, "day": day, "spend": spend,
                       "threshold": threshold}, sort_keys=True)


# ── payload contract + sink ──
def test_payload_is_hashed_and_contains_no_content():
    p = m1_alerts.build_payload("user_spend", uid="raw-user-123", spend=0.6,
                                cap=0.5, window="utc_day:20261021", ts=NOW)
    assert set(p) == {"kind", "uid_hash", "spend_usd", "cap_usd", "window", "timestamp"}
    assert p["uid_hash"] == hashlib.sha256(b"raw-user-123").hexdigest()
    assert p["spend_usd"] == pytest.approx(0.6) and p["cap_usd"] == pytest.approx(0.5)
    assert p["window"] == "utc_day:20261021"
    blob = json.dumps(p)
    assert "raw-user-123" not in blob and "@" not in blob and "prompt" not in blob


def test_webhook_sends_one_payload():
    sent, logs = [], []
    sink = m1_alerts.AlertSink(
        "https://alerts.example/hook",
        poster=lambda url, payload: sent.append((url, payload)),
        log=logs.append)
    p = m1_alerts.build_payload("user_spend", uid="u", spend=0.6, cap=0.5)
    assert sink.deliver(p) == "webhook"
    assert len(sent) == 1 and sent[0][0] == "https://alerts.example/hook"
    assert sent[0][1] == p
    assert logs == []


def test_webhook_failure_is_retried_once_then_falls_back_to_log():
    attempts, logs = [], []

    def down(url, payload):
        attempts.append(payload)
        raise RuntimeError("webhook down")

    sink = m1_alerts.AlertSink("https://alerts.example/hook", poster=down,
                               log=logs.append)
    p = m1_alerts.build_payload("user_spend", uid="secret-uid", spend=0.75, cap=0.5)
    assert sink.deliver(p) == "log_fallback"
    assert len(attempts) == 2                     # initial try + one retry
    assert len(logs) == 1 and "M1_ALERT_FALLBACK" in logs[0]
    logged = json.loads(logs[0].split(": ", 1)[1])
    assert logged == p
    assert "secret-uid" not in logs[0] and "prompt" not in logs[0]


def test_webhook_retry_can_succeed():
    calls = []

    def flaky(url, payload):
        calls.append(payload)
        if len(calls) == 1:
            raise RuntimeError("first attempt failed")

    sink = m1_alerts.AlertSink("https://alerts.example/hook", poster=flaky,
                               log=lambda line: pytest.fail(line))
    assert sink.deliver(m1_alerts.build_payload("user_spend", uid="u")) == "webhook"
    assert len(calls) == 2


def test_webhook_non_2xx_response_falls_back():
    class Response:
        status_code = 500

    logs = []
    sink = m1_alerts.AlertSink("https://alerts.example/hook",
                               poster=lambda url, payload: Response(),
                               log=logs.append)
    assert sink.deliver(m1_alerts.build_payload("user_spend", uid="u")) == "log_fallback"
    assert len(logs) == 1 and "M1_ALERT_FALLBACK" in logs[0]


def test_no_webhook_logs_the_payload():
    logs = []
    sink = m1_alerts.AlertSink("", log=logs.append)
    p = m1_alerts.build_payload("user_spend", uid="u", spend=0.6, cap=0.5)
    assert sink.deliver(p) == "log"
    assert len(logs) == 1 and "M1_ALERT" in logs[0]
    assert json.loads(logs[0].split("M1_ALERT ", 1)[1]) == p


# ── queue draining: once per user per day ──
def test_flush_delivers_once_per_user_per_day(env):
    mint, _, _ = env
    sink = RecordingSink()
    mint.ALERT_SINK = sink
    mint.rds.sadd(plans.SPEND_ALERT_PENDING, queued("user-1"))
    mint.rds.sadd(plans.SPEND_ALERT_PENDING, queued("user-2", spend=2.0))

    assert mint.flush_user_spend_alerts() == 2
    assert mint.flush_user_spend_alerts() == 0      # sent marker prevents repeats
    assert len(sink.payloads) == 2

    hashes = {p["uid_hash"] for p in sink.payloads}
    assert hashes == {hashlib.sha256(b"user-1").hexdigest(),
                      hashlib.sha256(b"user-2").hexdigest()}
    assert "user-1" not in json.dumps(sink.payloads)
    assert all(p["kind"] == "user_spend" and p["window"].startswith("utc_day:")
               for p in sink.payloads)


def test_flush_records_history_for_admin(client):
    c, mint, _, _ = client
    mint.ALERT_SINK = RecordingSink(delivery="log_fallback")
    mint.rds.sadd(plans.SPEND_ALERT_PENDING, queued("u"))
    assert mint.flush_user_spend_alerts() == 1

    body = c.get("/admin/alerts", headers=ADMIN).json()
    assert body["pending"] == 0
    assert body["webhook_configured"] is True
    assert len(body["alerts"]) == 1
    entry = body["alerts"][0]
    assert entry["kind"] == "user_spend" and entry["delivery"] == "log_fallback"
    assert entry["uid_hash"] == hashlib.sha256(b"u").hexdigest()
    assert "uid" not in entry and "@" not in json.dumps(entry)


# ── runtime kill switch + audit ──
def test_admin_kill_switch_denies_and_is_audited(client):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")

    r = c.post("/admin/kill-switch", headers=ADMIN, json={"enabled": True})
    assert r.status_code == 200, r.text
    assert r.json()["kill_switch"] == {"env": False, "runtime": True, "active": True}
    assert mint.rds.get(plans.KILL_SWITCH_KEY) == "1"

    denied = c.post("/mint", headers={"Authorization": "Bearer u", **AUTH})
    assert denied.status_code == 503
    assert denied.json()["detail"]["error"] == "paid_models_disabled"

    entries = c.get("/admin/audit", headers=ADMIN).json()["entries"]
    assert entries[0]["action"] == "kill-switch"
    assert entries[0]["before"]["active"] is False
    assert entries[0]["after"]["active"] is True

    r = c.post("/admin/kill-switch", headers=ADMIN, json={"enabled": False})
    assert r.json()["kill_switch"] == {"env": False, "runtime": False, "active": False}
    assert mint.rds.get(plans.KILL_SWITCH_KEY) is None
    assert c.post("/mint", headers={"Authorization": "Bearer u", **AUTH}).status_code == 200

    actions = [e["action"] for e in c.get("/admin/audit", headers=ADMIN).json()["entries"]]
    assert actions.count("kill-switch") == 2


def test_env_kill_switch_stays_the_hard_override(client, monkeypatch):
    c, mint, fake, _ = client
    user_with_keys(mint, fake, "u")
    monkeypatch.setenv(plans.KILL_SWITCH_ENV, "true")

    r = c.post("/admin/kill-switch", headers=ADMIN, json={"enabled": False})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["env_override"] is True
    assert body["kill_switch"] == {"env": True, "runtime": False, "active": True}
    assert mint.rds.get(plans.KILL_SWITCH_KEY) is None
    assert c.get("/admin/kill-switch", headers=ADMIN).json()["active"] is True
    denied = c.post("/mint", headers={"Authorization": "Bearer u", **AUTH})
    assert denied.status_code == 503
    assert denied.json()["detail"]["error"] == "paid_models_disabled"
