"""Per-key IP fan-out detection.

One Ovid virtual key is bound to one account and one platform.  A legitimate
mobile user can move between a handful of networks in a short time (Wi-Fi,
carrier CGNAT, a commute); a *leaked* key is typically used from many unrelated
networks at once.  This guard records the coarse network prefix (IPv4 ``/24``,
IPv6 ``/48``) each key is seen from and blocks the key when more than
``limit`` distinct prefixes appear inside ``window_seconds``.

Contract:

* ``> limit`` distinct prefixes in the window → the key is blocked, an operator
  email event is queued **exactly once per block event**, and callers get
  :class:`KeyIpFanoutBlocked` (``403 key_ip_fanout``).
* Observations while a key is already blocked raise the same exception without
  creating another event or another email.
* Admin unblock clears the block *and* the observation window, so the reviewed
  key does not instantly re-block.
* Normal multi-network mobile use (at or below the limit) is allowed.

No raw key is ever stored or returned here.  Keys are addressed by
:func:`key_ref`, a truncated SHA-256 fingerprint.  The email payload contains
the fingerprint, the account id, coarse prefixes and counters only — never the
key, the key hash, a bearer token or a full IP address.

Stores are pluggable.  :class:`MemoryKeyIpStore` is the deterministic test
double; :class:`RedisKeyIpStore` is the production store used by mint (the same
Redis instance that already holds the key ids).
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import threading
import time
from dataclasses import dataclass
from typing import Any, Protocol

DEFAULT_FANOUT_LIMIT = 5
DEFAULT_WINDOW_SECONDS = 15 * 60
DEFAULT_BLOCK_SECONDS = 24 * 60 * 60
DEFAULT_ALERT_RETENTION_SECONDS = 7 * 24 * 60 * 60
OBSERVATION_RETENTION_SECONDS = 2 * 60 * 60

REASON_KEY_IP_FANOUT = "key_ip_fanout"


class KeyIpFanoutBlocked(Exception):
    """A key was blocked because it fanned out across too many networks.

    ``new`` is true only for the observation that created the block; callers
    use it to block the key upstream / audit exactly once per event.
    """

    def __init__(self, key_ref: str, event_id: str | None = None,
                 reason: str = REASON_KEY_IP_FANOUT, *, new: bool = False,
                 blocked_until: float | None = None,
                 distinct_prefixes: int | None = None):
        self.key_ref = key_ref
        self.event_id = event_id
        self.reason = reason or REASON_KEY_IP_FANOUT
        self.new = new
        self.blocked_until = blocked_until
        self.distinct_prefixes = distinct_prefixes
        self.code = REASON_KEY_IP_FANOUT
        self.status = 403
        super().__init__(self.code)


@dataclass(frozen=True)
class KeyIpDecision:
    """Result of one allowed observation."""

    recorded: bool
    key_ref: str
    distinct_prefixes: int = 0
    reason: str | None = None
    event_id: str | None = None
    alerted: bool = False


class KeyIpStore(Protocol):
    def record(self, key_ref: str, prefix: str, seen_at: float) -> None: ...
    def distinct_prefixes(self, key_ref: str, since: float) -> list[str]: ...
    def clear_observations(self, key_ref: str) -> None: ...
    def blocked(self, key_ref: str, now: float) -> dict | None: ...
    def block(self, key_ref: str, record: dict, now: float,
              blocked_until: float) -> None: ...
    def list_blocks(self, now: float) -> list[dict]: ...
    def unblock(self, key_ref: str, now: float) -> dict | None: ...
    def claim_alert(self, event_key: str, now: float) -> bool: ...


def key_ref(key_id: str) -> str:
    """Stable, non-reversible key fingerprint (never the key or its full hash)."""
    if not isinstance(key_id, str) or not key_id:
        raise ValueError("Invalid key id")
    return "key_" + hashlib.sha256(key_id.encode("utf-8")).hexdigest()[:20]


def network_prefix(ip: str) -> str:
    """IPv4 ``/24`` or IPv6 ``/48`` for an address; raises on invalid input."""
    if not isinstance(ip, str) or not ip.strip():
        raise ValueError("Invalid address")
    address = ipaddress.ip_address(ip.strip())
    if address.version == 6 and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    bits = 24 if address.version == 4 else 48
    return str(ipaddress.ip_network(f"{address}/{bits}", strict=False))


class MemoryKeyIpStore:
    """In-process authority for tests and single-process tools."""

    def __init__(self):
        self._lock = threading.RLock()
        self._observations: dict[str, dict[str, float]] = {}
        self._blocks: dict[str, dict] = {}
        self._alerts: set[str] = set()

    def record(self, key_ref: str, prefix: str, seen_at: float) -> None:
        with self._lock:
            self._observations.setdefault(key_ref, {})[prefix] = float(seen_at)

    def distinct_prefixes(self, key_ref: str, since: float) -> list[str]:
        with self._lock:
            rows = self._observations.get(key_ref, {})
            return sorted(prefix for prefix, seen in rows.items()
                          if float(seen) >= float(since))

    def clear_observations(self, key_ref: str) -> None:
        with self._lock:
            self._observations.pop(key_ref, None)

    def blocked(self, key_ref: str, now: float) -> dict | None:
        with self._lock:
            record = self._blocks.get(key_ref)
            if record is None:
                return None
            if float(record["blocked_until"]) <= float(now):
                self._blocks.pop(key_ref, None)
                return None
            return dict(record)

    def block(self, key_ref: str, record: dict, now: float,
              blocked_until: float) -> None:
        with self._lock:
            self._blocks[key_ref] = dict(record)

    def list_blocks(self, now: float) -> list[dict]:
        with self._lock:
            out = []
            for ref in list(self._blocks):
                record = self.blocked(ref, now)
                if record is not None:
                    out.append(record)
            return sorted(out, key=lambda row: row.get("blocked_at", 0), reverse=True)

    def unblock(self, key_ref: str, now: float) -> dict | None:
        with self._lock:
            record = self.blocked(key_ref, now)
            self._blocks.pop(key_ref, None)
            return record

    def claim_alert(self, event_key: str, now: float) -> bool:
        with self._lock:
            if event_key in self._alerts:
                return False
            self._alerts.add(event_key)
            return True


class RedisKeyIpStore:
    """Redis authority shared by every mint instance.

    The client is a ``redis-py`` client with ``decode_responses=True``.  Only
    the handful of commands already used by mint are required (hashes, sets,
    ``SET NX EX`` and expiry), so the in-memory test double keeps working too.
    """

    def __init__(self, client, *, prefix: str = "security:keyip:"):
        self.client = client
        self.prefix = prefix

    def _observations_key(self, key_ref: str) -> str:
        return f"{self.prefix}obs:{key_ref}"

    def _block_key(self, key_ref: str) -> str:
        return f"{self.prefix}block:{key_ref}"

    def _blocks_set(self) -> str:
        return f"{self.prefix}blocks"

    def _alert_key(self, event_key: str) -> str:
        return f"{self.prefix}alert:{event_key}"

    def record(self, key_ref: str, prefix: str, seen_at: float) -> None:
        key = self._observations_key(key_ref)
        self.client.hset(key, prefix, f"{float(seen_at):.3f}")
        self.client.expire(key, OBSERVATION_RETENTION_SECONDS)

    def distinct_prefixes(self, key_ref: str, since: float) -> list[str]:
        rows = self.client.hgetall(self._observations_key(key_ref)) or {}
        out = []
        for prefix, seen in rows.items():
            try:
                if float(seen) >= float(since):
                    out.append(prefix)
            except (TypeError, ValueError):
                continue
        return sorted(out)

    def clear_observations(self, key_ref: str) -> None:
        self.client.delete(self._observations_key(key_ref))

    def _decode(self, raw: dict | None) -> dict | None:
        if not raw:
            return None
        record: dict[str, Any] = dict(raw)
        for field in ("blocked_at", "blocked_until"):
            try:
                record[field] = float(record.get(field) or 0)
            except (TypeError, ValueError):
                record[field] = 0.0
        try:
            record["distinct_prefixes"] = int(record.get("distinct_prefixes") or 0)
        except (TypeError, ValueError):
            record["distinct_prefixes"] = 0
        raw_prefixes = record.get("prefixes")
        if isinstance(raw_prefixes, str):
            try:
                parsed = json.loads(raw_prefixes)
            except ValueError:
                parsed = []
            record["prefixes"] = parsed if isinstance(parsed, list) else []
        elif not isinstance(raw_prefixes, list):
            record["prefixes"] = []
        return record

    def blocked(self, key_ref: str, now: float) -> dict | None:
        key = self._block_key(key_ref)
        record = self._decode(self.client.hgetall(key))
        if record is None:
            return None
        if float(record["blocked_until"]) <= float(now):
            self.client.delete(key)
            self.client.srem(self._blocks_set(), key_ref)
            return None
        return record

    def block(self, key_ref: str, record: dict, now: float,
              blocked_until: float) -> None:
        fields = {
            "key_ref": key_ref,
            "uid": str(record.get("uid") or ""),
            "platform": str(record.get("platform") or ""),
            "reason": str(record.get("reason") or REASON_KEY_IP_FANOUT),
            "event_id": str(record.get("event_id") or ""),
            "blocked_at": f"{float(now):.3f}",
            "blocked_until": f"{float(blocked_until):.3f}",
            "distinct_prefixes": str(int(record.get("distinct_prefixes") or 0)),
            "prefixes": json.dumps(list(record.get("prefixes") or [])),
        }
        key = self._block_key(key_ref)
        self.client.hset(key, mapping=fields)
        ttl = max(60, int(float(blocked_until) - float(now)) + 60)
        self.client.expire(key, ttl)
        self.client.sadd(self._blocks_set(), key_ref)

    def list_blocks(self, now: float) -> list[dict]:
        out = []
        for ref in list(self.client.smembers(self._blocks_set()) or []):
            record = self.blocked(ref, now)
            if record is not None:
                out.append(record)
        return sorted(out, key=lambda row: row.get("blocked_at", 0), reverse=True)

    def unblock(self, key_ref: str, now: float) -> dict | None:
        record = self.blocked(key_ref, now)
        self.client.delete(self._block_key(key_ref))
        self.client.srem(self._blocks_set(), key_ref)
        return record

    def claim_alert(self, event_key: str, now: float) -> bool:
        return bool(self.client.set(
            self._alert_key(event_key), "1", nx=True,
            ex=DEFAULT_ALERT_RETENTION_SECONDS))


class KeyIpFanoutGuard:
    """Record key network prefixes and block a key that fans out too widely."""

    def __init__(self, store: KeyIpStore, *, limit: int = DEFAULT_FANOUT_LIMIT,
                 window_seconds: float = DEFAULT_WINDOW_SECONDS,
                 block_seconds: float = DEFAULT_BLOCK_SECONDS,
                 email_hook=None, clock=time.time):
        if int(limit) < 1:
            raise ValueError("limit must be at least 1")
        if float(window_seconds) <= 0 or float(block_seconds) <= 0:
            raise ValueError("Invalid fan-out window/block duration")
        self.store = store
        self.limit = int(limit)
        self.window_seconds = float(window_seconds)
        self.block_seconds = float(block_seconds)
        self.email_hook = email_hook
        self.clock = clock

    def check(self, key_id: str, *, now: float | None = None) -> None:
        """Raise :class:`KeyIpFanoutBlocked` if this key is already blocked."""
        now = self.clock() if now is None else float(now)
        ref = key_ref(key_id)
        record = self.store.blocked(ref, now)
        if record is not None:
            raise KeyIpFanoutBlocked(
                ref, record.get("event_id"), record.get("reason"), new=False,
                blocked_until=record.get("blocked_until"),
                distinct_prefixes=record.get("distinct_prefixes"))

    def observe(self, key_id: str, uid: str, ip: str, *,
                platform: str | None = None, now: float | None = None,
                seen_at: float | None = None) -> KeyIpDecision:
        """Record one sighting of ``key_id`` from ``ip``.

        ``now`` is the decision time (defaults to the clock); ``seen_at`` lets a
        caller replay a historical observation (LiteLLM spend logs) while the
        block itself is applied now.
        """
        now = self.clock() if now is None else float(now)
        seen_at = now if seen_at is None else float(seen_at)
        ref = key_ref(key_id)

        # An existing block always wins, even for an observation without an IP.
        self.check(key_id, now=now)

        try:
            prefix = network_prefix(ip)
        except ValueError:
            return KeyIpDecision(recorded=False, key_ref=ref,
                                 reason="invalid_address")

        self.store.record(ref, prefix, seen_at)
        prefixes = self.store.distinct_prefixes(ref, now - self.window_seconds)
        if len(prefixes) <= self.limit:
            return KeyIpDecision(recorded=True, key_ref=ref,
                                 distinct_prefixes=len(prefixes))

        event_id = f"{ref}:{int(now)}:{REASON_KEY_IP_FANOUT}"
        alerted = False
        if self.store.claim_alert(event_id, now):
            event = self._email_event(ref, uid, platform, prefixes, event_id, now)
            self._enqueue_email(event)
            alerted = True

        record = {
            "key_ref": ref,
            "uid": uid,
            "platform": platform or "",
            "reason": REASON_KEY_IP_FANOUT,
            "event_id": event_id,
            "blocked_at": float(now),
            "blocked_until": float(now) + self.block_seconds,
            "distinct_prefixes": len(prefixes),
            "prefixes": sorted(prefixes),
        }
        self.store.block(ref, record, now, now + self.block_seconds)
        raise KeyIpFanoutBlocked(
            ref, event_id, REASON_KEY_IP_FANOUT, new=True,
            blocked_until=record["blocked_until"],
            distinct_prefixes=len(prefixes))

    def blocked_keys(self, *, now: float | None = None) -> list[dict]:
        now = self.clock() if now is None else float(now)
        return self.store.list_blocks(now)

    def block_for(self, ref: str, *, now: float | None = None) -> dict | None:
        now = self.clock() if now is None else float(now)
        return self.store.blocked(ref, now)

    def unblock(self, ref: str, *, actor: str, reason: str,
                now: float | None = None) -> dict | None:
        """Clear a block and its observation window (reviewed key may resume)."""
        if not isinstance(actor, str) or not actor.strip():
            raise ValueError("Invalid admin actor")
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError("Invalid unblock reason")
        now = self.clock() if now is None else float(now)
        record = self.store.unblock(ref, now)
        if record is None:
            return None
        self.store.clear_observations(ref)
        return record

    def _enqueue_email(self, event: dict) -> None:
        hook = self.email_hook
        if hook is None:
            return
        try:
            if callable(hook):
                hook(event)
                return
            enqueue = getattr(hook, "enqueue", None) or getattr(hook, "send", None)
            if not callable(enqueue):
                raise TypeError("Email hook must be callable or expose enqueue/send")
            enqueue(event)
        except Exception:
            # Security detection must not fail because the mail transport is
            # down.  The block still applies; the event is visible to admins.
            pass

    def _email_event(self, ref: str, uid: str, platform: str | None,
                     prefixes: list[str], event_id: str, now: float) -> dict:
        return {
            "type": REASON_KEY_IP_FANOUT,
            "event_id": event_id,
            "key_ref": ref,
            "uid": uid,
            "platform": platform,
            "reason": REASON_KEY_IP_FANOUT,
            "distinct_prefixes": len(prefixes),
            "prefixes": sorted(prefixes),
            "limit": self.limit,
            "window_seconds": int(self.window_seconds),
            "blocked_at": int(now),
            "blocked_until": int(now + self.block_seconds),
            "at": int(now),
        }
