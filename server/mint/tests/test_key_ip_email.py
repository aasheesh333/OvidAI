"""The key-suspension email: message shape and transport.

The block path already queued an event, but `KEY_IP_EMAIL_SENDER` was left
`None`, so `flush_key_ip_emails` only printed the payload to stdout. A user
whose key was blocked for cross-IP fan-out never learned why — the product
spec promises "you account has found suspended because of suspicious
activity".

No network here: the transport takes an injected POST so the payload is
pinned without a provider.
"""

from __future__ import annotations

import sys
from pathlib import Path

# This suite is pure (no Redis, no mint fixture), so put the mint directory on
# the path itself rather than relying on the mint fixture's setup.
_MINT_DIR = Path(__file__).resolve().parents[1]
if str(_MINT_DIR) not in sys.path:
    sys.path.insert(0, str(_MINT_DIR))

import mail  # noqa: E402


EVENT = {
    "type": "key_ip_fanout",
    "event_id": "evt-1",
    "key_ref": "abc123",
    "uid": "user-1",
    "platform": "android",
    "reason": "key_ip_fanout",
    "distinct_prefixes": 7,
    "limit": 5,
    "window_seconds": 900,
    "blocked_at": "2026-10-23T10:00:00Z",
    "blocked_until": "2026-10-24T10:00:00Z",
    "at": "2026-10-23T10:00:01Z",
}


def test_message_names_the_reason_and_the_restore_time():
    msg = mail.suspension_message(EVENT, to="user@example.test")
    assert msg["to"] == "user@example.test"
    assert "suspended" in msg["subject"].lower()
    text = msg["text"]
    assert "suspicious activity" in text.lower()
    assert "2026-10-24T10:00:00Z" in text
    assert "support" in text.lower()


def test_message_never_leaks_the_key_or_the_raw_ip():
    event = dict(EVENT)
    event["key"] = "sk-live-secret"
    event["ip"] = "203.0.113.9"
    msg = mail.suspension_message(event, to="user@example.test")
    blob = msg["subject"] + msg["text"] + msg["html"]
    assert "sk-live-secret" not in blob
    assert "203.0.113.9" not in blob


def test_recipient_prefers_the_payload_address_then_the_operator_fallback():
    with_addr = dict(EVENT, email="person@example.test")
    assert mail.recipient_for(with_addr, operator_fallback="ops@example.test") == (
        "person@example.test"
    )
    assert mail.recipient_for(EVENT, operator_fallback="ops@example.test") == (
        "ops@example.test"
    )
    assert mail.recipient_for(EVENT, operator_fallback="") is None


def test_transport_is_not_configured_without_an_api_key():
    assert mail.sender_from_env({}) is None
    assert mail.sender_from_env({"OVID_MAIL_API_KEY": "  "}) is None


def test_transport_posts_the_message_to_the_provider():
    calls = []

    def fake_post(url, headers, body, timeout):
        calls.append({"url": url, "headers": headers, "body": body, "timeout": timeout})
        return 200

    sender = mail.sender_from_env(
        {
            "OVID_MAIL_API_KEY": "re_test",
            "OVID_MAIL_FROM": "Ovid Si <security@ovidsi.com>",
            "OVID_SECURITY_ALERT_TO": "ops@example.test",
        },
        http_post=fake_post,
    )
    assert sender is not None
    assert sender(EVENT) is True

    assert len(calls) == 1
    call = calls[0]
    assert call["url"] == mail.RESEND_URL
    assert call["headers"]["Authorization"] == "Bearer re_test"
    assert call["body"]["from"] == "Ovid Si <security@ovidsi.com>"
    assert call["body"]["to"] == ["ops@example.test"]


def test_a_provider_failure_is_reported_not_swallowed():
    sender = mail.sender_from_env(
        {
            "OVID_MAIL_API_KEY": "re_test",
            "OVID_MAIL_FROM": "security@ovidsi.com",
            "OVID_SECURITY_ALERT_TO": "ops@example.test",
        },
        http_post=lambda *a, **k: 500,
    )
    assert sender is not None
    assert sender(EVENT) is False


def test_no_recipient_means_no_request():
    calls = []
    sender = mail.sender_from_env(
        {
            "OVID_MAIL_API_KEY": "re_test",
            "OVID_MAIL_FROM": "security@ovidsi.com",
        },
        http_post=lambda *a, **k: calls.append(a) or 200,
    )
    assert sender is not None
    assert sender(EVENT) is False
    assert calls == []
