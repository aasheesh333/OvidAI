"""Key-suspension email: the message and its transport.

`mint.flush_key_ip_emails` already dequeued an event and recorded it in
`/admin/alerts`, but `KEY_IP_EMAIL_SENDER` was left `None`, so the only
"delivery" was a stdout line. A user whose key was blocked for cross-IP
fan-out never learned why.

Two pieces live here:

* `suspension_message` builds the copy from a WHITELIST of event fields, so a
  stray `key`, `ip` or prompt can never reach an inbox.
* `sender_from_env` returns the delivery callable, or None when no provider is
  configured (the caller then keeps the event in the queue and the admin
  alert history — never a silent drop).

The transport is Resend's HTTPS API; `http_post` is injected so the payload is
pinned without a network.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Callable, Mapping

RESEND_URL = "https://api.resend.com/emails"
SUPPORT_URL = "https://ovidsi.com/support"
REQUEST_TIMEOUT_S = 10

# The ONLY event fields the copy may read. Everything else (key, key_ref,
# network addresses, prompts) is either secret or personal.
_SAFE_FIELDS = (
    "type",
    "event_id",
    "uid",
    "platform",
    "reason",
    "distinct_prefixes",
    "limit",
    "window_seconds",
    "blocked_at",
    "blocked_until",
)


def _escaped(value: object) -> str:
    text = "" if value is None else str(value)
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def recipient_for(event: Mapping, operator_fallback: str = "") -> str | None:
    """The user's address when the account service supplied one, else the
    operator inbox. Blank means "nowhere to send" — never a guessed address."""
    for candidate in (event.get("email"), operator_fallback):
        if isinstance(candidate, str) and candidate.strip():
            return candidate.strip()
    return None


def suspension_message(event: Mapping, to: str) -> dict:
    """Subject/text/html for one block event. Whitelisted fields only."""
    safe = {k: event.get(k) for k in _SAFE_FIELDS if event.get(k) is not None}
    until = str(safe.get("blocked_until") or "24 hours from now")
    platform = str(safe.get("platform") or "your device")

    subject = "Your Ovid Si account has been suspended"
    text = (
        "Hello,\n\n"
        "Your Ovid Si account has found suspended because of suspicious "
        "activity: this account's key was used from an unusually high number "
        "of different networks in a short window.\n\n"
        f"Access is blocked until {until}. No request from this key is being "
        "served while the block is active.\n\n"
        "If this was you (for example a new phone or a VPN), or if you think "
        "this is a mistake, contact support and we will restore access:\n"
        f"{SUPPORT_URL}\n\n"
        f"Reference: {safe.get('event_id') or 'n/a'}\n"
        f"Platform: {platform}\n"
        "— Ovid Si Security\n"
    )
    html = (
        "<p>Hello,</p>"
        "<p>Your Ovid Si account has found suspended because of "
        "<strong>suspicious activity</strong>: this account's key was used "
        "from an unusually high number of different networks in a short "
        "window.</p>"
        f"<p>Access is blocked until <strong>{_escaped(until)}</strong>. No "
        "request from this key is being served while the block is active.</p>"
        "<p>If this was you (for example a new phone or a VPN), or if you "
        "think this is a mistake, contact support and we will restore "
        f'access: <a href="{SUPPORT_URL}">{SUPPORT_URL}</a></p>'
        f"<p>Reference: {_escaped(safe.get('event_id') or 'n/a')}<br>"
        f"Platform: {_escaped(platform)}</p>"
        "<p>— Ovid Si Security</p>"
    )
    return {"to": to, "subject": subject, "text": text, "html": html}


def _default_http_post(url: str, headers: dict, body: dict, timeout: float) -> int:
    data = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            return int(getattr(response, "status", 0) or 0)
    except urllib.error.HTTPError as e:  # a provider 4xx/5xx is an answer
        return int(e.code)
    except Exception:  # noqa: BLE001 — transport failure is "not delivered"
        return 0


def sender_from_env(
    env: Mapping[str, str] | None = None,
    http_post: Callable[[str, dict, dict, float], int] | None = None,
) -> Callable[[Mapping], bool] | None:
    """The delivery callable, or None when no provider is configured.

    None is not an error: the caller keeps the queued event and the admin
    alert row, so nothing is lost — it is simply not emailed.
    """
    source = os.environ if env is None else env
    api_key = str(source.get("OVID_MAIL_API_KEY") or "").strip()
    sender = str(source.get("OVID_MAIL_FROM") or "").strip()
    fallback = str(source.get("OVID_SECURITY_ALERT_TO") or "").strip()
    if not api_key or not sender:
        return None
    post = http_post or _default_http_post

    def send(payload: Mapping) -> bool:
        to = recipient_for(payload, operator_fallback=fallback)
        if to is None:
            # Nothing to send to. Report "not delivered" so the caller keeps
            # the event in the alert history instead of claiming success.
            return False
        message = suspension_message(payload, to=to)
        try:
            status = post(
                RESEND_URL,
                {
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                {
                    "from": sender,
                    "to": [to],
                    "subject": message["subject"],
                    "text": message["text"],
                    "html": message["html"],
                },
                REQUEST_TIMEOUT_S,
            )
        except Exception:  # noqa: BLE001 — a send failure must not break the block
            return False
        return 200 <= int(status) < 300

    return send
