"""Per-route token buckets: burst, refill, isolation and admin overrides.

The behavioural tests run against both stores: the in-memory authority and the
Redis implementation behind a small in-process client.  The fake client executes
the same token arithmetic the Lua script describes and supports the handful of
Redis commands the store uses, so the store's keying, result parsing and
override bookkeeping are exercised without a live Redis server.
"""

import math

import pytest

from server.security.rate_limits import (
    ROUTE_COLLAB_JOIN,
    ROUTE_MINT,
    ROUTE_USAGE,
    MemoryTokenBucketStore,
    RateLimited,
    RateLimiter,
    RateLimitUnavailable,
    RedisTokenBucketStore,
    RouteLimit,
)

T0 = 1_000.0


class FakeRedis:
    """Minimal redis-py surface used by :class:`RedisTokenBucketStore`."""

    def __init__(self):
        self.buckets = {}
        self.hashes = {}
        self.sets = {}

    # Lua consumption contract: capacity, refill, now, cost -> decision.
    def eval(self, script, numkeys, key, *args):
        capacity, refill, now, cost = (float(value) for value in args)
        tokens, updated_at = self.buckets.get(key, (capacity, now))
        if now > updated_at:
            tokens = min(capacity, tokens + (now - updated_at) * refill)
            updated_at = now
        if tokens >= cost:
            tokens -= cost
            allowed, retry_after = 1, 0
        else:
            allowed = 0
            retry_after = max(1, math.ceil((cost - tokens) / refill))
        self.buckets[key] = (tokens, updated_at)
        return [allowed, str(tokens), retry_after]

    def hset(self, key, mapping=None, **kwargs):
        self.hashes.setdefault(key, {}).update(mapping or kwargs)

    def hgetall(self, key):
        return dict(self.hashes.get(key, {}))

    def expire(self, key, ttl):
        return True

    def persist(self, key):
        return True

    def sadd(self, key, value):
        self.sets.setdefault(key, set()).add(value)

    def srem(self, key, value):
        self.sets.get(key, set()).discard(value)

    def smembers(self, key):
        return set(self.sets.get(key, set()))

    def delete(self, *keys):
        for key in keys:
            self.buckets.pop(key, None)
            self.hashes.pop(key, None)
            self.sets.pop(key, None)


@pytest.fixture(params=["memory", "redis"])
def limiter(request):
    if request.param == "memory":
        store = MemoryTokenBucketStore()
    else:
        store = RedisTokenBucketStore(FakeRedis())
    return RateLimiter(store, limits={ROUTE_MINT: (3, 1.0)}, clock=lambda: T0)


def test_burst_is_allowed_then_429_with_retry_after(limiter):
    for expected in (2, 1, 0):
        decision = limiter.enforce("user-1", ROUTE_MINT, now=T0)
        assert decision.allowed is True
        assert int(decision.remaining) == expected

    with pytest.raises(RateLimited) as caught:
        limiter.enforce("user-1", ROUTE_MINT, now=T0)
    error = caught.value
    assert error.code == "rate_limited" and error.status == 429
    assert error.retry_after == 1
    assert error.headers["Retry-After"] == "1"
    assert error.headers["X-RateLimit-Limit"] == "3"
    assert error.headers["X-RateLimit-Remaining"] == "0"
    assert error.to_dict()["route"] == ROUTE_MINT

    # check() reports the same rejection without raising.
    decision = limiter.check("user-1", ROUTE_MINT, now=T0)
    assert decision.allowed is False and decision.retry_after == 1


def test_bucket_refills_continuously_and_caps_at_capacity():
    limiter = RateLimiter(
        MemoryTokenBucketStore(),
        limits={ROUTE_MINT: (2, 0.5)}, clock=lambda: T0)

    assert limiter.enforce("u", ROUTE_MINT, now=T0).allowed
    assert limiter.enforce("u", ROUTE_MINT, now=T0).allowed
    assert limiter.check("u", ROUTE_MINT, now=T0).retry_after == 2

    # Half a token after one second: still short of the one token needed.
    denied = limiter.check("u", ROUTE_MINT, now=T0 + 1)
    assert denied.allowed is False and denied.retry_after == 1

    allowed = limiter.enforce("u", ROUTE_MINT, now=T0 + 2)
    assert allowed.allowed is True

    # A long idle period refills to the cap, never beyond it.
    after_idle = limiter.enforce("u", ROUTE_MINT, now=T0 + 1_000)
    assert math.isclose(after_idle.limit, 2)
    assert int(after_idle.remaining) == 1


@pytest.mark.parametrize("store_factory", [
    MemoryTokenBucketStore,
    lambda: RedisTokenBucketStore(FakeRedis()),
], ids=["memory", "redis"])
def test_users_and_routes_have_independent_buckets(store_factory):
    limiter = RateLimiter(
        store_factory(),
        limits={ROUTE_MINT: (2, 1.0), ROUTE_USAGE: (2, 1.0)},
        clock=lambda: T0)

    assert limiter.enforce("alice", ROUTE_MINT, now=T0).allowed
    assert limiter.enforce("alice", ROUTE_MINT, now=T0).allowed
    with pytest.raises(RateLimited):
        limiter.enforce("alice", ROUTE_MINT, now=T0)

    # Another user is untouched by Alice's burst.
    assert limiter.enforce("bob", ROUTE_MINT, now=T0).allowed
    assert limiter.enforce("bob", ROUTE_MINT, now=T0).allowed

    # And Alice can still use a different route.
    assert limiter.enforce("alice", ROUTE_USAGE, now=T0).allowed


def test_admin_override_raises_limit_and_applies_immediately(limiter):
    assert limiter.enforce("user-1", ROUTE_MINT, now=T0).allowed
    assert limiter.enforce("user-1", ROUTE_MINT, now=T0).allowed
    assert limiter.enforce("user-1", ROUTE_MINT, now=T0).allowed
    with pytest.raises(RateLimited):
        limiter.enforce("user-1", ROUTE_MINT, now=T0)

    override = limiter.set_override(
        "user-1", ROUTE_MINT, capacity=5, refill_per_second=1.0,
        ttl_seconds=600, actor="admin-7", reason="support session", now=T0)
    assert override["capacity"] == 5
    assert override["expires_at"] == T0 + 600
    assert override["actor"] == "admin-7"

    # The bucket was reset, so the larger burst is usable right away.
    for _ in range(5):
        decision = limiter.enforce("user-1", ROUTE_MINT, now=T0)
        assert decision.allowed and decision.overridden is True
    with pytest.raises(RateLimited):
        limiter.enforce("user-1", ROUTE_MINT, now=T0)

    # Overrides are per user, not global.
    assert limiter.enforce("user-2", ROUTE_MINT, now=T0).allowed
    listed = limiter.overrides(now=T0)
    assert [(row["uid"], row["route"]) for row in listed] == [
        ("user-1", ROUTE_MINT)]


def test_admin_override_can_lower_a_limit_and_clear_restores_default(limiter):
    limiter.set_override("user-1", ROUTE_MINT, capacity=1,
                         refill_per_second=1.0, actor="admin",
                         reason="throttle abuse", now=T0)
    assert limiter.enforce("user-1", ROUTE_MINT, now=T0).allowed
    with pytest.raises(RateLimited):
        limiter.enforce("user-1", ROUTE_MINT, now=T0)

    removed = limiter.clear_override(
        "user-1", ROUTE_MINT, actor="admin", reason="appeal upheld", now=T0)
    assert removed["reason"] == "throttle abuse"
    assert limiter.overrides(now=T0) == []

    # Back to the route default (burst 3) with a fresh bucket.
    for _ in range(3):
        decision = limiter.enforce("user-1", ROUTE_MINT, now=T0)
        assert decision.allowed and decision.overridden is False
    with pytest.raises(RateLimited):
        limiter.enforce("user-1", ROUTE_MINT, now=T0)


@pytest.mark.parametrize("store_factory", [
    MemoryTokenBucketStore,
    lambda: RedisTokenBucketStore(FakeRedis()),
], ids=["memory", "redis"])
def test_expired_override_falls_back_to_the_default(store_factory):
    limiter = RateLimiter(
        store_factory(), limits={ROUTE_MINT: (2, 1.0)}, clock=lambda: T0)
    limiter.set_override("u", ROUTE_MINT, capacity=4, refill_per_second=1.0,
                         ttl_seconds=30, actor="admin", reason="trial",
                         now=T0)
    assert limiter.check("u", ROUTE_MINT, now=T0).limit == 4
    assert limiter.overrides(now=T0 + 31) == []
    decision = limiter.check("u", ROUTE_MINT, now=T0 + 31)
    assert decision.overridden is False and decision.limit == 2


def test_override_requires_an_actor_reason_and_known_route(limiter):
    with pytest.raises(ValueError):
        limiter.set_override("user-1", ROUTE_MINT, capacity=5,
                             actor="", reason="x", now=T0)
    with pytest.raises(ValueError):
        limiter.set_override("user-1", ROUTE_MINT, capacity=5,
                             actor="admin", reason="  ", now=T0)
    with pytest.raises(ValueError):
        limiter.set_override("user-1", "not_a_route", capacity=5,
                             actor="admin", reason="x", now=T0)
    with pytest.raises(ValueError):
        limiter.set_override("user-1", ROUTE_MINT, capacity=0,
                             actor="admin", reason="x", now=T0)
    with pytest.raises(ValueError):
        limiter.set_override("user-1", ROUTE_MINT, capacity=5, ttl_seconds=0,
                             actor="admin", reason="x", now=T0)
    with pytest.raises(ValueError):
        limiter.set_override("bad user", ROUTE_MINT, capacity=5,
                             actor="admin", reason="x", now=T0)


def test_unknown_route_and_bad_cost_are_rejected(limiter):
    with pytest.raises(ValueError):
        limiter.check("user-1", "unknown", now=T0)
    with pytest.raises(ValueError):
        limiter.check("user-1", ROUTE_MINT, cost=0, now=T0)


def test_each_default_route_has_a_sensible_burst_and_refill():
    limiter = RateLimiter(MemoryTokenBucketStore(), clock=lambda: T0)
    for route in (ROUTE_MINT, ROUTE_USAGE, ROUTE_COLLAB_JOIN):
        limit = limiter.limit_for(route)
        assert limit.capacity >= 1 and limit.refill_per_second > 0
    # A join is expensive: its sustained rate is intentionally the lowest.
    assert (limiter.limit_for(ROUTE_COLLAB_JOIN).refill_per_second
            < limiter.limit_for(ROUTE_USAGE).refill_per_second)
    with pytest.raises(ValueError):
        RouteLimit(ROUTE_MINT, 0, 1)


def test_fail_open_by_default_and_fail_closed_when_configured():
    class BrokenStore:
        def override_for(self, uid, route, now):
            raise RuntimeError("redis down")

        def consume(self, *args, **kwargs):
            raise RuntimeError("redis down")

    open_limiter = RateLimiter(BrokenStore(), clock=lambda: T0)
    decision = open_limiter.check("u", ROUTE_MINT, now=T0)
    assert decision.allowed is True and decision.degraded is True

    closed_limiter = RateLimiter(BrokenStore(), clock=lambda: T0,
                                 fail_open=False)
    with pytest.raises(RateLimitUnavailable) as caught:
        closed_limiter.enforce("u", ROUTE_MINT, now=T0)
    assert caught.value.status == 503
    assert caught.value.code == "rate_limit_unavailable"
