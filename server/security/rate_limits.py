"""Per-route token-bucket rate limits for authenticated API calls.

Each ``(user, route)`` pair owns an independent bucket.  A bucket starts full
with ``capacity`` tokens, refills continuously at ``refill_per_second`` and
spends one token per call (or ``cost`` tokens when a route is weighted).  Calls
that find fewer tokens than they cost are rejected with HTTP ``429`` and a
``Retry-After`` header, without resetting the bucket.

Routes covered by default:

===============  ========  ==================
route            burst     sustained
===============  ========  ==================
``mint``             20    0.5/s (30/min)
``usage``            60    1/s (60/min)
``sharing``          30    0.25/s (15/min)
``collab_join``      10    0.1/s (6/min)
``artifact_upload``  10    0.2/s (12/min)
===============  ========  ==================

The numbers are deliberately per *user*, not per IP: a shared office or carrier
NAT must not lock everybody out, while a single account cannot hammer an
endpoint.  Per-IP protections live in mint's sign-up and fan-out guards.

Admins can grant a temporary override for one user and route, for example a
support session that needs a larger burst.  An override replaces both the burst
and the refill rate, may expire after ``ttl_seconds``, records the actor and
reason, and resets that user's bucket so the new limit applies immediately.  A
missing override means the route default; expired overrides are removed lazily.

Stores are pluggable.  :class:`MemoryTokenBucketStore` is the deterministic
in-process implementation used by tests and single-host services;
:class:`RedisTokenBucketStore` keeps the counters in Redis for multi-instance
deployments.  The Redis implementation uses one Lua script per call so a burst
of concurrent requests can never overspend a bucket (``GET`` + ``SET`` would
race).  If Redis is unavailable the limiter fails open by default so an outage
does not take the API down; construct it with ``fail_open=False`` to reject with
``503 rate_limit_unavailable`` instead.

Route handlers call :func:`enforce_route`; a process-wide registry
(:func:`register_limiter`) lets the application factory install one limiter at
startup without every route module importing the store classes.  With no
limiter registered :func:`enforce_route` allows the request and reports
``degraded=True``, so a missing wiring step never blocks authentication.

No request bodies, tokens or IP addresses are stored here: a bucket key is the
route plus the opaque user id, and override rows keep only the admin's actor id
and the reason text.
"""

from __future__ import annotations

import hashlib
import math
import re
import threading
import time
from dataclasses import dataclass
from types import MappingProxyType
from typing import Iterable, Mapping, Protocol

ROUTE_MINT = "mint"
ROUTE_USAGE = "usage"
ROUTE_SHARING = "sharing"
ROUTE_COLLAB_JOIN = "collab_join"
ROUTE_ARTIFACT_UPLOAD = "artifact_upload"

REASON_RATE_LIMITED = "rate_limited"
REASON_UNAVAILABLE = "rate_limit_unavailable"

DEFAULT_KEY_PREFIX = "security:rate:"

_ROUTE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_UID_RE = re.compile(r"^[A-Za-z0-9_.@+-]{1,128}$")


def _positive_number(value, name: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a positive number")
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{name} must be a positive number") from None
    if not math.isfinite(number) or number <= 0:
        raise ValueError(f"{name} must be a positive number")
    return number


@dataclass(frozen=True)
class RouteLimit:
    """Burst capacity and refill rate for one route."""

    route: str
    capacity: float
    refill_per_second: float

    def __post_init__(self) -> None:
        if not isinstance(self.route, str) or not _ROUTE_RE.fullmatch(self.route):
            raise ValueError("Invalid rate-limit route name")
        capacity = _positive_number(self.capacity, "capacity")
        refill = _positive_number(self.refill_per_second, "refill_per_second")
        object.__setattr__(self, "capacity", capacity)
        object.__setattr__(self, "refill_per_second", refill)


#: Default limits.  Kept as a read-only mapping so a caller cannot mutate the
#: process-wide defaults by accident.
DEFAULT_LIMITS: Mapping[str, RouteLimit] = MappingProxyType({
    ROUTE_MINT: RouteLimit(ROUTE_MINT, capacity=20, refill_per_second=0.5),
    ROUTE_USAGE: RouteLimit(ROUTE_USAGE, capacity=60, refill_per_second=1.0),
    ROUTE_SHARING: RouteLimit(ROUTE_SHARING, capacity=30, refill_per_second=0.25),
    ROUTE_COLLAB_JOIN: RouteLimit(
        ROUTE_COLLAB_JOIN, capacity=10, refill_per_second=0.1),
    ROUTE_ARTIFACT_UPLOAD: RouteLimit(
        ROUTE_ARTIFACT_UPLOAD, capacity=10, refill_per_second=0.2),
})


@dataclass(frozen=True)
class RateLimitDecision:
    """Outcome of one token-bucket check."""

    route: str
    uid: str
    allowed: bool
    limit: float
    remaining: float
    retry_after: int = 0
    reset_at: float = 0.0
    overridden: bool = False
    degraded: bool = False

    def headers(self) -> dict[str, str]:
        """Response headers for an allowed or rejected request."""
        out = {
            "X-RateLimit-Limit": str(max(0, int(self.limit))),
            "X-RateLimit-Remaining": str(max(0, int(self.remaining))),
            "X-RateLimit-Reset": str(int(math.ceil(self.reset_at))),
        }
        if not self.allowed:
            out["Retry-After"] = str(max(1, int(self.retry_after)))
        return out

    def to_dict(self) -> dict:
        return {
            "route": self.route,
            "allowed": self.allowed,
            "limit": int(self.limit),
            "remaining": max(0, int(self.remaining)),
            "retry_after": int(self.retry_after),
            "reset_at": int(math.ceil(self.reset_at)),
            "overridden": self.overridden,
            "degraded": self.degraded,
        }


class RateLimited(Exception):
    """A request exceeded its bucket; render as ``429`` with retry headers."""

    code = REASON_RATE_LIMITED
    status = 429

    def __init__(self, decision: RateLimitDecision):
        self.decision = decision
        self.route = decision.route
        self.uid = decision.uid
        self.retry_after = max(1, int(decision.retry_after))
        self.limit = decision.limit
        self.remaining = decision.remaining
        self.reset_at = decision.reset_at
        super().__init__(self.code)

    @property
    def headers(self) -> dict[str, str]:
        return self.decision.headers()

    def to_dict(self) -> dict:
        body = self.decision.to_dict()
        body["code"] = self.code
        return body


class RateLimitUnavailable(Exception):
    """The limiter store is down and the caller configured fail-closed."""

    code = REASON_UNAVAILABLE
    status = 503

    def __init__(self, detail: str = ""):
        self.detail = detail or self.code
        super().__init__(self.code)


class TokenBucketStore(Protocol):
    """Storage surface shared by the memory and Redis implementations."""

    def consume(self, key: str, capacity: float, refill_per_second: float,
                now: float, cost: float = 1.0) -> tuple[bool, float, int]:
        """Spend ``cost`` from ``key``; return (allowed, tokens, retry_after)."""
        ...

    def reset(self, key: str) -> None: ...

    def set_override(self, record: dict) -> None: ...

    def override_for(self, uid: str, route: str, now: float) -> dict | None: ...

    def list_overrides(self, now: float) -> list[dict]: ...

    def delete_override(self, uid: str, route: str,
                        now: float) -> dict | None: ...


class MemoryTokenBucketStore:
    """In-process authority for tests and single-process deployments."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._buckets: dict[str, tuple[float, float]] = {}
        self._overrides: dict[tuple[str, str], dict] = {}

    def consume(self, key: str, capacity: float, refill_per_second: float,
                now: float, cost: float = 1.0) -> tuple[bool, float, int]:
        with self._lock:
            capacity = float(capacity)
            refill = float(refill_per_second)
            now = float(now)
            cost = float(cost)
            state = self._buckets.get(key)
            if state is None:
                tokens, updated_at = capacity, now
            else:
                tokens, updated_at = state
                if now > updated_at:
                    tokens = min(capacity, tokens + (now - updated_at) * refill)
                    updated_at = now
            if tokens >= cost:
                tokens -= cost
                allowed, retry_after = True, 0
            else:
                allowed = False
                retry_after = max(1, int(math.ceil((cost - tokens) / refill)))
            self._buckets[key] = (tokens, updated_at)
            return allowed, max(0.0, tokens), retry_after

    def reset(self, key: str) -> None:
        with self._lock:
            self._buckets.pop(key, None)

    def set_override(self, record: dict) -> None:
        with self._lock:
            self._overrides[(record["uid"], record["route"])] = dict(record)

    def override_for(self, uid: str, route: str, now: float) -> dict | None:
        with self._lock:
            record = self._overrides.get((uid, route))
            if record is None:
                return None
            expires_at = record.get("expires_at")
            if expires_at is not None and float(expires_at) <= float(now):
                self._overrides.pop((uid, route), None)
                return None
            return dict(record)

    def list_overrides(self, now: float) -> list[dict]:
        with self._lock:
            out = []
            for key in list(self._overrides):
                record = self.override_for(key[0], key[1], now)
                if record is not None:
                    out.append(record)
            return sorted(out, key=lambda row: row.get("created_at", 0),
                          reverse=True)

    def delete_override(self, uid: str, route: str, now: float) -> dict | None:
        with self._lock:
            record = self.override_for(uid, route, now)
            self._overrides.pop((uid, route), None)
            return record


# KEYS[1] bucket hash
# ARGV[1] capacity, ARGV[2] refill/s, ARGV[3] now, ARGV[4] cost
# Returns {allowed (0/1), tokens as string, retry_after seconds (int)}.
_CONSUME_LUA = """
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4])

local state = redis.call('HMGET', key, 'tokens', 'updated_at')
local tokens = tonumber(state[1])
local updated_at = tonumber(state[2])
if tokens == nil then tokens = capacity end
if updated_at == nil then updated_at = now end

if now > updated_at then
  tokens = math.min(capacity, tokens + (now - updated_at) * refill)
  updated_at = now
end

local allowed = 0
local retry_after = 0
if tokens >= cost then
  tokens = tokens - cost
  allowed = 1
else
  retry_after = math.ceil((cost - tokens) / refill)
  if retry_after < 1 then retry_after = 1 end
end

redis.call('HSET', key, 'tokens', tostring(tokens), 'updated_at', tostring(now))
local ttl = math.ceil(capacity / refill) + 120
redis.call('EXPIRE', key, ttl)
return {allowed, tostring(tokens), retry_after}
"""


class RedisTokenBucketStore:
    """Shared token buckets for more than one API instance.

    ``client`` is a ``redis-py`` client (``decode_responses=True`` recommended).
    Consumption is a single atomic Lua script, so concurrent requests from
    different processes cannot both spend the last token.  Overrides live in
    hashes and are indexed by a set for admin listing.
    """

    def __init__(self, client, *, prefix: str = DEFAULT_KEY_PREFIX):
        self.client = client
        self.prefix = prefix

    # ── buckets ──────────────────────────────────────────────────────────
    def consume(self, key: str, capacity: float, refill_per_second: float,
                now: float, cost: float = 1.0) -> tuple[bool, float, int]:
        result = self.client.eval(
            _CONSUME_LUA, 1, key, _num(capacity), _num(refill_per_second),
            _num(now), _num(cost))
        try:
            allowed = bool(int(result[0]))
            tokens = float(_text(result[1]))
            retry_after = int(float(_text(result[2])))
        except (TypeError, ValueError, IndexError) as exc:
            raise ValueError("Invalid rate-limit script response") from exc
        return allowed, max(0.0, tokens), max(0, retry_after)

    def reset(self, key: str) -> None:
        self.client.delete(key)

    # ── admin overrides ──────────────────────────────────────────────────
    def _override_key(self, uid: str, route: str) -> str:
        digest = hashlib.sha256(f"{uid}\0{route}".encode("utf-8")).hexdigest()
        return f"{self.prefix}override:{digest[:32]}"

    def _override_set(self) -> str:
        return f"{self.prefix}overrides"

    def _decode_override(self, raw: dict | None) -> dict | None:
        if not raw:
            return None
        raw = {_text(k): v for k, v in raw.items()}
        try:
            expires_raw = _text(raw.get("expires_at") or "")
            override = {
                "uid": _text(raw.get("uid") or ""),
                "route": _text(raw.get("route") or ""),
                "capacity": float(_text(raw.get("capacity") or 0)),
                "refill_per_second": float(
                    _text(raw.get("refill_per_second") or 0)),
                "expires_at": float(expires_raw) if expires_raw else None,
                "actor": _text(raw.get("actor") or ""),
                "reason": _text(raw.get("reason") or ""),
                "created_at": float(_text(raw.get("created_at") or 0)),
            }
        except (TypeError, ValueError):
            return None
        if override["uid"] == "" or override["route"] == "":
            return None
        return override

    def set_override(self, record: dict) -> None:
        key = self._override_key(record["uid"], record["route"])
        expires_at = record.get("expires_at")
        fields = {
            "uid": record["uid"],
            "route": record["route"],
            "capacity": _num(record["capacity"]),
            "refill_per_second": _num(record["refill_per_second"]),
            "expires_at": _num(expires_at) if expires_at is not None else "",
            "actor": record.get("actor") or "",
            "reason": record.get("reason") or "",
            "created_at": _num(record.get("created_at") or 0),
        }
        self.client.hset(key, mapping=fields)
        if expires_at is not None:
            ttl = max(1, int(math.ceil(float(expires_at) - time.time())) + 60)
            self.client.expire(key, ttl)
        else:
            self.client.persist(key)
        self.client.sadd(self._override_set(), key)

    def override_for(self, uid: str, route: str, now: float) -> dict | None:
        key = self._override_key(uid, route)
        record = self._decode_override(self.client.hgetall(key))
        if record is None:
            return None
        expires_at = record.get("expires_at")
        if expires_at is not None and float(expires_at) <= float(now):
            self.client.delete(key)
            self.client.srem(self._override_set(), key)
            return None
        return record

    def list_overrides(self, now: float) -> list[dict]:
        out = []
        for key in list(self.client.smembers(self._override_set()) or []):
            key = _text(key)
            record = self._decode_override(self.client.hgetall(key))
            if record is None:
                self.client.srem(self._override_set(), key)
                continue
            expires_at = record.get("expires_at")
            if expires_at is not None and float(expires_at) <= float(now):
                self.client.delete(key)
                self.client.srem(self._override_set(), key)
                continue
            out.append(record)
        return sorted(out, key=lambda row: row.get("created_at", 0),
                      reverse=True)

    def delete_override(self, uid: str, route: str, now: float) -> dict | None:
        record = self.override_for(uid, route, now)
        key = self._override_key(uid, route)
        self.client.delete(key)
        self.client.srem(self._override_set(), key)
        return record


class RateLimiter:
    """Resolve a route's limit, spend a token and raise :class:`RateLimited`."""

    def __init__(self, store: TokenBucketStore, *,
                 limits: Mapping[str, RouteLimit | tuple[float, float]] | None = None,
                 clock=time.time, fail_open: bool = True,
                 prefix: str = DEFAULT_KEY_PREFIX):
        merged = dict(DEFAULT_LIMITS)
        for route, value in (limits or {}).items():
            if isinstance(value, RouteLimit):
                merged[route] = value
            elif isinstance(value, (tuple, list)) and len(value) == 2:
                merged[route] = RouteLimit(route, value[0], value[1])
            else:
                raise TypeError("limit must be RouteLimit or (capacity, refill)")
        self.store = store
        self.limits = MappingProxyType(merged)
        self.clock = clock
        self.fail_open = bool(fail_open)
        self.prefix = prefix

    def limit_for(self, route: str) -> RouteLimit:
        try:
            return self.limits[route]
        except KeyError:
            raise ValueError(f"Unknown rate-limit route: {route}") from None

    def bucket_key(self, uid: str, route: str) -> str:
        return f"{self.prefix}{route}:{uid}"

    def check(self, uid: str, route: str, *, cost: float = 1.0,
              now: float | None = None) -> RateLimitDecision:
        """Spend tokens for one call and return the decision (never raises 429)."""
        uid = _uid(uid)
        limit = self.limit_for(route)
        cost = _positive_number(cost, "cost")
        now = self.clock() if now is None else float(now)

        overridden = False
        try:
            override = self.store.override_for(uid, route, now)
        except Exception:
            if not self.fail_open:
                raise RateLimitUnavailable("override lookup failed")
            override, degraded = None, True
        else:
            degraded = False

        if override is not None:
            try:
                limit = RouteLimit(route, override["capacity"],
                                   override["refill_per_second"])
                overridden = True
            except (KeyError, TypeError, ValueError):
                pass  # corrupt override: keep the route default

        try:
            allowed, tokens, retry_after = self.store.consume(
                self.bucket_key(uid, route), limit.capacity,
                limit.refill_per_second, now, cost)
        except Exception:
            if not self.fail_open:
                raise RateLimitUnavailable("bucket store unavailable")
            return RateLimitDecision(
                route=route, uid=uid, allowed=True, limit=limit.capacity,
                remaining=limit.capacity, retry_after=0, reset_at=now,
                overridden=overridden, degraded=True)

        retry_after = 0 if allowed else max(1, int(retry_after))
        reset_at = now + retry_after
        return RateLimitDecision(
            route=route, uid=uid, allowed=allowed, limit=limit.capacity,
            remaining=max(0.0, tokens), retry_after=retry_after,
            reset_at=reset_at, overridden=overridden, degraded=degraded)

    def enforce(self, uid: str, route: str, *, cost: float = 1.0,
                now: float | None = None) -> RateLimitDecision:
        """Like :meth:`check`, but raise :class:`RateLimited` on rejection."""
        decision = self.check(uid, route, cost=cost, now=now)
        if not decision.allowed:
            raise RateLimited(decision)
        return decision

    # ── admin ────────────────────────────────────────────────────────────
    def set_override(self, uid: str, route: str, *, capacity: float,
                     refill_per_second: float | None = None,
                     ttl_seconds: float | None = None,
                     actor: str, reason: str,
                     now: float | None = None) -> dict:
        """Grant one user a larger/smaller bucket for one route.

        ``ttl_seconds`` of ``None`` keeps the override until it is cleared.  A
        new override resets that user's bucket so it takes effect immediately.
        """
        uid = _uid(uid)
        limit = self.limit_for(route)
        capacity = _positive_number(capacity, "capacity")
        refill = (limit.refill_per_second if refill_per_second is None
                  else _positive_number(refill_per_second,
                                        "refill_per_second"))
        if ttl_seconds is not None:
            ttl_seconds = _positive_number(ttl_seconds, "ttl_seconds")
        actor = _admin_text(actor, "actor")
        reason = _admin_text(reason, "reason")
        now = self.clock() if now is None else float(now)
        record = {
            "uid": uid,
            "route": route,
            "capacity": capacity,
            "refill_per_second": refill,
            "expires_at": None if ttl_seconds is None else now + ttl_seconds,
            "actor": actor,
            "reason": reason,
            "created_at": now,
        }
        self.store.set_override(record)
        self.store.reset(self.bucket_key(uid, route))
        return dict(record)

    def clear_override(self, uid: str, route: str, *, actor: str,
                       reason: str, now: float | None = None) -> dict | None:
        """Remove an override (recording who did it) and reset the bucket."""
        uid = _uid(uid)
        self.limit_for(route)
        _admin_text(actor, "actor")
        _admin_text(reason, "reason")
        now = self.clock() if now is None else float(now)
        record = self.store.delete_override(uid, route, now)
        if record is not None:
            self.store.reset(self.bucket_key(uid, route))
        return record

    def overrides(self, *, now: float | None = None) -> list[dict]:
        now = self.clock() if now is None else float(now)
        return self.store.list_overrides(now)


# ── process-wide wiring ──────────────────────────────────────────────────
#
# WIRED-BY: server/mint/mint.py (/mint and /usage), server/shares/api.py
# (POST/PUT/DELETE /shares*), server/collaboration/api.py (POST "" to join and
# POST /{session_token}/files for artifact upload).  Those route modules own
# the request lifecycle and are outside this change's scope.  Their handlers
# call ``enforce_route(uid, ROUTE_*, ...)`` before doing work and translate
# ``RateLimited.headers`` / ``RateLimitUnavailable`` onto the error response
# (``429`` with ``Retry-After`` / ``503``).

_LIMITERS: dict[str, RateLimiter] = {}
_LIMITERS_LOCK = threading.Lock()


def register_limiter(limiter: RateLimiter | None,
                     routes: Iterable[str] | None = None) -> None:
    """Install the process-wide limiter that :func:`enforce_route` uses.

    ``routes`` selects the routes to wire and defaults to every route the
    limiter knows about.  ``None`` removes every registration, which makes
    :func:`enforce_route` allow requests.  Registering again replaces the
    limiter for the affected routes.
    """
    if limiter is not None and not isinstance(limiter, RateLimiter):
        raise TypeError("limiter must be a RateLimiter or None")
    if routes is not None and isinstance(routes, str):
        raise TypeError("routes must be an iterable of route names")
    if limiter is None:
        with _LIMITERS_LOCK:
            _LIMITERS.clear()
        return
    selected = tuple(limiter.limits if routes is None else routes)
    for route in selected:
        limiter.limit_for(route)  # reject an unknown route name loudly
    with _LIMITERS_LOCK:
        for route in selected:
            _LIMITERS[route] = limiter


def route_limiter(route: str) -> RateLimiter | None:
    """Return the registered limiter for ``route``, if any."""
    with _LIMITERS_LOCK:
        return _LIMITERS.get(route)


def registered_routes() -> tuple[str, ...]:
    """Routes currently wired through :func:`enforce_route`."""
    with _LIMITERS_LOCK:
        return tuple(sorted(_LIMITERS))


def enforce_route(uid: str, route: str, *, cost: float = 1.0,
                  now: float | None = None) -> RateLimitDecision:
    """Enforce the registered limiter for ``route`` for one user.

    Raises :class:`RateLimited` when the bucket is exhausted and
    :class:`RateLimitUnavailable` when a fail-closed store is down.  With no
    limiter registered (control disabled) the request is allowed with
    ``degraded=True``; that keeps a missing registration from rejecting traffic.
    """
    limiter = route_limiter(route)
    if limiter is None:
        limit = DEFAULT_LIMITS.get(route)
        if limit is None:
            raise ValueError(f"Unknown rate-limit route: {route}")
        uid = _uid(uid)
        now = time.time() if now is None else float(now)
        return RateLimitDecision(
            route=route, uid=uid, allowed=True, limit=limit.capacity,
            remaining=limit.capacity, retry_after=0, reset_at=now,
            degraded=True)
    return limiter.enforce(uid, route, cost=cost, now=now)


# ── helpers ───────────────────────────────────────────────────────────────

def _uid(uid: str) -> str:
    if not isinstance(uid, str) or not _UID_RE.fullmatch(uid):
        raise ValueError("Invalid user id")
    return uid


def _admin_text(value: str, name: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 500:
        raise ValueError(f"Invalid admin {name}")
    return value.strip()


def _num(value) -> str:
    return f"{float(value):.6f}"


def _text(value) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return "" if value is None else str(value)
