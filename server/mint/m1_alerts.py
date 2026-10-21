"""M1 alert delivery: webhook with a log fallback.

The LiteLLM hook only *queues* structured alert items in Redis (it has no
transport). Mint drains the queue and hands each item to an :class:`AlertSink`.
A sink:

* sends exactly one JSON payload per alert to ``M1_ALERT_WEBHOOK_URL``;
* retries the webhook once on failure;
* falls back to logging the same payload when no webhook is configured or both
  attempts fail.

Payloads are deliberately small and safe to forward: the uid is SHA-256 hashed
and there is no message/prompt content, no API key, no token and no email.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import time

DEFAULT_TIMEOUT_S = 5.0
SAFE_KEYS = ("kind", "uid_hash", "spend_usd", "cap_usd", "window", "timestamp")


def hash_uid(uid: str) -> str:
    """Stable, non-reversible uid fingerprint for alert payloads."""
    return hashlib.sha256(str(uid).encode("utf-8")).hexdigest()


def utc_iso(ts: float | None = None) -> str:
    return (datetime.datetime.fromtimestamp(float(time.time() if ts is None else ts),
                                           datetime.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"))


def build_payload(kind: str, *, uid: str | None = None, spend: float | None = None,
                  cap: float | None = None, window: str = "utc_day",
                  ts: float | None = None) -> dict:
    """One alert payload. Only these fields are ever sent or logged."""
    return {
        "kind": kind,
        "uid_hash": hash_uid(uid) if uid else None,
        "spend_usd": None if spend is None else round(float(spend), 6),
        "cap_usd": None if cap is None else round(float(cap), 6),
        "window": window,
        "timestamp": utc_iso(ts),
    }


def _sanitize(payload: dict) -> dict:
    """Drop anything that is not part of the documented payload."""
    return {k: payload.get(k) for k in SAFE_KEYS}


def _http_post(url: str, payload: dict, timeout: float) -> None:
    import httpx

    r = httpx.post(url, json=payload, timeout=timeout)
    if r.status_code >= 400:
        raise RuntimeError(f"webhook HTTP {r.status_code}")


class AlertSink:
    """Injectable M1 alert transport (webhook, then log).

    ``poster`` and ``log`` are injectable so tests never touch the network.
    ``poster(url, payload)`` may raise on failure; ``log(line)`` receives a
    single line containing the JSON payload.
    """

    def __init__(self, webhook_url: str = "", *, poster=None, log=None,
                 timeout: float = DEFAULT_TIMEOUT_S, retries: int = 1):
        self.webhook_url = (webhook_url or "").strip()
        self.timeout = timeout
        self.retries = max(0, int(retries))
        self._poster = poster or (lambda url, payload: _http_post(url, payload, self.timeout))
        self._log = log or (lambda line: print(line, flush=True))

    def deliver(self, payload: dict) -> str:
        """Deliver one alert. Returns ``webhook``, ``log`` or ``log_fallback``.

        Never raises: alerting must not break the sweeper or an admin request.
        """
        body = _sanitize(payload)
        line = json.dumps(body, sort_keys=True, separators=(",", ":"))
        if not self.webhook_url:
            self._log(f"[mint] M1_ALERT {line}")
            return "log"

        last_error = "unknown"
        for attempt in range(1 + self.retries):
            try:
                result = self._poster(self.webhook_url, body)
                status = getattr(result, "status_code", None)
                if status is not None and int(status) >= 400:
                    raise RuntimeError(f"webhook HTTP {status}")
                if result is False:
                    raise RuntimeError("webhook poster returned False")
                return "webhook"
            except Exception as e:  # noqa: BLE001 — fall back, never fail the caller
                last_error = type(e).__name__
                if attempt < self.retries:
                    continue
        self._log(f"[mint] M1_ALERT_FALLBACK webhook failed ({last_error}): {line}")
        return "log_fallback"

    # Convenience alias for callers/tests that think in terms of "send".
    send = deliver
